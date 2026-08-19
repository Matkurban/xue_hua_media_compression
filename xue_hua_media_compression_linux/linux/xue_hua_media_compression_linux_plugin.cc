#include "include/xue_hua_media_compression_linux/xue_hua_media_compression_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <glib/gstdio.h>
#include <vips/vips.h>

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "image_vips.h"
#include "messages.g.h"
#include "video_vaapi.h"

#define XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(obj)                        \
  (G_TYPE_CHECK_INSTANCE_CAST((obj),                                       \
                              xue_hua_media_compression_linux_plugin_get_type(), \
                              XueHuaMediaCompressionLinuxPlugin))

struct EventStream {
  FlEventChannel* channel = nullptr;
  bool listening = false;
  FlValue* last_progress = nullptr;
  std::vector<FlValue*> pending_terminal;
  gint64 last_progress_us = 0;

  ~EventStream() {
    if (last_progress) fl_value_unref(last_progress);
    for (FlValue* value : pending_terminal) fl_value_unref(value);
    if (channel) g_object_unref(channel);
  }

  void Send(FlValue* value, bool is_progress) {
    if (listening) {
      if (is_progress) {
        const gint64 now = g_get_monotonic_time();
        if (now - last_progress_us < 100000) {
          if (last_progress) fl_value_unref(last_progress);
          last_progress = value;
          return;
        }
        last_progress_us = now;
      }
      fl_event_channel_send(channel, value, nullptr, nullptr);
      fl_value_unref(value);
    } else if (is_progress) {
      if (last_progress) fl_value_unref(last_progress);
      last_progress = value;
    } else {
      pending_terminal.push_back(value);
    }
  }
};

static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue*, gpointer user_data) {
  auto* stream = static_cast<EventStream*>(user_data);
  stream->listening = true;
  if (stream->last_progress) {
    fl_event_channel_send(channel, stream->last_progress, nullptr, nullptr);
    fl_value_unref(stream->last_progress);
    stream->last_progress = nullptr;
  }
  for (FlValue* value : stream->pending_terminal) {
    fl_event_channel_send(channel, value, nullptr, nullptr);
    fl_value_unref(value);
  }
  stream->pending_terminal.clear();
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel*, FlValue*,
                                              gpointer user_data) {
  static_cast<EventStream*>(user_data)->listening = false;
  return nullptr;
}

struct Job {
  int64_t id = 0;
  std::unique_ptr<EventStream> events;
  std::atomic<bool> cancelled{false};
  bool started = false;
};

struct _XueHuaMediaCompressionLinuxPlugin {
  GObject parent_instance;
  FlBinaryMessenger* messenger;
  std::map<int64_t, std::unique_ptr<Job>>* jobs;
  int64_t next_id;
};

G_DEFINE_TYPE(XueHuaMediaCompressionLinuxPlugin,
              xue_hua_media_compression_linux_plugin, G_TYPE_OBJECT)

static Job* JobOf(XueHuaMediaCompressionLinuxPlugin* self, int64_t id) {
  auto it = self->jobs->find(id);
  return it == self->jobs->end() ? nullptr : it->second.get();
}

static void PostToMain(const std::function<void()>& task) {
  auto* heap = new std::function<void()>(task);
  g_idle_add(
      [](gpointer data) -> gboolean {
        auto* fn = static_cast<std::function<void()>*>(data);
        (*fn)();
        delete fn;
        return G_SOURCE_REMOVE;
      },
      heap);
}

static std::unique_ptr<EventStream> MakeEventStream(FlBinaryMessenger* messenger,
                                                    int64_t id) {
  auto stream = std::make_unique<EventStream>();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  const std::string name =
      "xue_hua_media_compression/job_events_" + std::to_string(id);
  stream->channel =
      fl_event_channel_new(messenger, name.c_str(), FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(stream->channel, event_listen_cb,
                                       event_cancel_cb, stream.get(), nullptr);
  return stream;
}

static XhMcMediaCompressionHostApiCreateJobResponse* handle_create_job(
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  const int64_t id = self->next_id++;
  auto job = std::make_unique<Job>();
  job->id = id;
  job->events = MakeEventStream(self->messenger, id);
  self->jobs->emplace(id, std::move(job));
  return xh_mc_media_compression_host_api_create_job_response_new(id);
}

static XhMcMediaCompressionHostApiQueryImageCapabilitiesResponse*
handle_query_image(gpointer) {
  return xh_mc_media_compression_host_api_query_image_capabilities_response_new(
      query_image_capabilities_vips());
}

static void handle_start_image(
    int64_t id, XhMcSourceMsg* source, XhMcDestinationMsg* destination,
    XhMcImageOptionsMsg* options,
    XhMcMediaCompressionHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  Job* job = JobOf(self, id);
  if (job == nullptr) {
    xh_mc_media_compression_host_api_respond_error_start_image_compress(
        response_handle, "instanceNotFound", "No job", nullptr);
    return;
  }
  if (job->started) {
    xh_mc_media_compression_host_api_respond_error_start_image_compress(
        response_handle, "invalidState", "Already started", nullptr);
    return;
  }
  job->started = true;
  xh_mc_media_compression_host_api_respond_start_image_compress(response_handle);
  g_object_ref(source);
  g_object_ref(destination);
  g_object_ref(options);
  EventStream* events = job->events.get();
  std::thread([job, source, destination, options, events]() {
    char* code = nullptr;
    char* message = nullptr;
    FlValue* result =
        compress_image_vips(source, destination, options, &code, &message);
    g_object_unref(source);
    g_object_unref(destination);
    g_object_unref(options);
    PostToMain([job, events, result, code, message]() {
      if (job->cancelled.load()) {
        FlValue* map = fl_value_new_map();
        fl_value_set_string_take(map, "type", fl_value_new_string("error"));
        fl_value_set_string_take(map, "code", fl_value_new_string("cancelled"));
        fl_value_set_string_take(map, "message",
                                 fl_value_new_string("Cancelled"));
        events->Send(map, false);
        if (result) fl_value_unref(result);
      } else if (result) {
        FlValue* progress = fl_value_new_map();
        fl_value_set_string_take(progress, "type",
                                 fl_value_new_string("progress"));
        fl_value_set_string_take(progress, "value", fl_value_new_float(1.0));
        events->Send(progress, true);
        FlValue* map = fl_value_new_map();
        fl_value_set_string_take(map, "type",
                                 fl_value_new_string("completed"));
        fl_value_set_string_take(map, "result", result);
        events->Send(map, false);
      } else {
        FlValue* map = fl_value_new_map();
        fl_value_set_string_take(map, "type", fl_value_new_string("error"));
        fl_value_set_string_take(map, "code",
                                 fl_value_new_string(code ? code : "encode"));
        fl_value_set_string_take(
            map, "message",
            fl_value_new_string(message ? message : "Image compress failed"));
        events->Send(map, false);
      }
      g_free(code);
      g_free(message);
    });
  }).detach();
}

static XhMcMediaCompressionHostApiQueryVideoCapabilitiesResponse*
handle_query_video(gpointer) {
  return xh_mc_media_compression_host_api_query_video_capabilities_response_new(
      query_video_capabilities_vaapi());
}

static void handle_start_video(
    int64_t id, const gchar* input_path, const gchar* output_path,
    XhMcVideoOptionsMsg* options,
    XhMcMediaCompressionHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  Job* job = JobOf(self, id);
  if (job == nullptr) {
    xh_mc_media_compression_host_api_respond_error_start_video_compress(
        response_handle, "instanceNotFound", "No job", nullptr);
    return;
  }
  if (job->started) {
    xh_mc_media_compression_host_api_respond_error_start_video_compress(
        response_handle, "invalidState", "Already started", nullptr);
    return;
  }
  job->started = true;
  xh_mc_media_compression_host_api_respond_start_video_compress(response_handle);
  g_object_ref(options);
  std::string in = input_path;
  std::string out = output_path;
  EventStream* events = job->events.get();
  std::thread([job, in, out, options, events]() {
    compress_video_vaapi(
        in, out, options, &job->cancelled,
        [events](double value) {
          PostToMain([events, value]() {
            FlValue* map = fl_value_new_map();
            fl_value_set_string_take(map, "type",
                                     fl_value_new_string("progress"));
            fl_value_set_string_take(map, "value", fl_value_new_float(value));
            events->Send(map, true);
          });
        },
        [events](FlValue* result) {
          PostToMain([events, result]() {
            FlValue* map = fl_value_new_map();
            fl_value_set_string_take(map, "type",
                                     fl_value_new_string("completed"));
            fl_value_set_string_take(map, "result", result);
            events->Send(map, false);
          });
        },
        [events](const char* code, const char* message) {
          std::string c = code;
          std::string m = message;
          PostToMain([events, c, m]() {
            FlValue* map = fl_value_new_map();
            fl_value_set_string_take(map, "type", fl_value_new_string("error"));
            fl_value_set_string_take(map, "code", fl_value_new_string(c.c_str()));
            fl_value_set_string_take(map, "message",
                                     fl_value_new_string(m.c_str()));
            events->Send(map, false);
          });
        });
    g_object_unref(options);
  }).detach();
}

static XhMcMediaCompressionHostApiCancelJobResponse* handle_cancel(
    int64_t id, gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  Job* job = JobOf(self, id);
  if (job == nullptr) {
    return xh_mc_media_compression_host_api_cancel_job_response_new_error(
        "instanceNotFound", "No job", nullptr);
  }
  job->cancelled.store(true);
  return xh_mc_media_compression_host_api_cancel_job_response_new();
}

static XhMcMediaCompressionHostApiDisposeJobResponse* handle_dispose(
    int64_t id, gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  self->jobs->erase(id);
  return xh_mc_media_compression_host_api_dispose_job_response_new();
}

static const XhMcMediaCompressionHostApiVTable kVtable = {
    .create_job = handle_create_job,
    .query_image_capabilities = handle_query_image,
    .start_image_compress = handle_start_image,
    .query_video_capabilities = handle_query_video,
    .start_video_compress = handle_start_video,
    .cancel_job = handle_cancel,
    .dispose_job = handle_dispose,
};

static void xue_hua_media_compression_linux_plugin_dispose(GObject* object) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(object);
  delete self->jobs;
  self->jobs = nullptr;
  G_OBJECT_CLASS(xue_hua_media_compression_linux_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_media_compression_linux_plugin_class_init(
    XueHuaMediaCompressionLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_media_compression_linux_plugin_dispose;
}

static void xue_hua_media_compression_linux_plugin_init(
    XueHuaMediaCompressionLinuxPlugin* self) {
  self->jobs = new std::map<int64_t, std::unique_ptr<Job>>();
  self->next_id = 1;
}

void xue_hua_media_compression_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  VIPS_INIT("xue_hua_media_compression");
  XueHuaMediaCompressionLinuxPlugin* plugin =
      XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(g_object_new(
          xue_hua_media_compression_linux_plugin_get_type(), nullptr));
  plugin->messenger = fl_plugin_registrar_get_messenger(registrar);
  xh_mc_media_compression_host_api_set_method_handlers(
      plugin->messenger, nullptr, &kVtable, g_object_ref(plugin),
      g_object_unref);
  g_object_unref(plugin);
}

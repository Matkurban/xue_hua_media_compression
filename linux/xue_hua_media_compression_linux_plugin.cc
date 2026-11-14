#include "include/xue_hua_media_compression/xue_hua_media_compression_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <glib/gstdio.h>
#include <vips/vips.h>

#include <algorithm>
#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include "image_vips.h"
#include "messages.g.h"
#include "video_gst.h"

#define XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(obj)                        \
  (G_TYPE_CHECK_INSTANCE_CAST((obj),                                       \
                              xue_hua_media_compression_linux_plugin_get_type(), \
                              XueHuaMediaCompressionLinuxPlugin))

struct Job {
  int64_t id = 0;
  XhMcMediaCompressionFlutterApi* flutter_api = nullptr;
  std::atomic<bool> cancelled{false};
  bool started = false;
  bool closed = false;
  bool terminal = false;
  bool sent_positive = false;
  int64_t last_progress_sent_us = 0;
  std::optional<double> last_progress;

  ~Job() {
    if (flutter_api != nullptr) {
      g_object_unref(flutter_api);
      flutter_api = nullptr;
    }
  }
};

struct _XueHuaMediaCompressionLinuxPlugin {
  GObject parent_instance;
  FlBinaryMessenger* messenger;
  std::map<int64_t, std::shared_ptr<Job>>* jobs;
  int64_t next_id;
};

G_DEFINE_TYPE(XueHuaMediaCompressionLinuxPlugin,
              xue_hua_media_compression_linux_plugin, G_TYPE_OBJECT)

static std::shared_ptr<Job> JobOf(XueHuaMediaCompressionLinuxPlugin* self,
                                  int64_t id) {
  auto it = self->jobs->find(id);
  return it == self->jobs->end() ? nullptr : it->second;
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

static void on_progress_done(GObject* source, GAsyncResult* res, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(XhMcMediaCompressionFlutterApiOnProgressResponse) response =
      xh_mc_media_compression_flutter_api_on_progress_finish(
          XH_MC_MEDIA_COMPRESSION_FLUTTER_API(source), res, &error);
  (void)response;
}

static void on_image_completed_done(GObject* source, GAsyncResult* res,
                                    gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(XhMcMediaCompressionFlutterApiOnImageCompletedResponse) response =
      xh_mc_media_compression_flutter_api_on_image_completed_finish(
          XH_MC_MEDIA_COMPRESSION_FLUTTER_API(source), res, &error);
  (void)response;
}

static void on_video_completed_done(GObject* source, GAsyncResult* res,
                                    gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(XhMcMediaCompressionFlutterApiOnVideoCompletedResponse) response =
      xh_mc_media_compression_flutter_api_on_video_completed_finish(
          XH_MC_MEDIA_COMPRESSION_FLUTTER_API(source), res, &error);
  (void)response;
}

static void on_error_done(GObject* source, GAsyncResult* res, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(XhMcMediaCompressionFlutterApiOnErrorResponse) response =
      xh_mc_media_compression_flutter_api_on_error_finish(
          XH_MC_MEDIA_COMPRESSION_FLUTTER_API(source), res, &error);
  (void)response;
}

static void SendProgress(const std::shared_ptr<Job>& job, double value) {
  if (job->closed || job->terminal || job->flutter_api == nullptr) {
    return;
  }
  const double clamped = std::max(0.0, std::min(1.0, value));
  const int64_t now_us = g_get_monotonic_time();
  const bool first_positive =
      clamped > 0.0 && clamped < 1.0 && !job->sent_positive;
  if (!first_positive && clamped < 1.0 &&
      (now_us - job->last_progress_sent_us) < 100000) {
    job->last_progress = clamped;
    return;
  }
  if (first_positive) {
    job->sent_positive = true;
  }
  job->last_progress_sent_us = now_us;
  job->last_progress.reset();
  xh_mc_media_compression_flutter_api_on_progress(
      job->flutter_api, clamped, nullptr, on_progress_done, nullptr);
}

static void SendImageCompleted(const std::shared_ptr<Job>& job,
                               XhMcImageCompressResultMsg* result) {
  if (job->closed || job->terminal || job->flutter_api == nullptr) {
    return;
  }
  job->terminal = true;
  if (job->last_progress.has_value()) {
    const double pending = *job->last_progress;
    job->last_progress.reset();
    xh_mc_media_compression_flutter_api_on_progress(
        job->flutter_api, pending, nullptr, on_progress_done, nullptr);
  }
  xh_mc_media_compression_flutter_api_on_image_completed(
      job->flutter_api, result, nullptr, on_image_completed_done, nullptr);
}

static void SendVideoCompleted(const std::shared_ptr<Job>& job,
                               XhMcVideoCompressResultMsg* result) {
  if (job->closed || job->terminal || job->flutter_api == nullptr) {
    return;
  }
  job->terminal = true;
  if (job->last_progress.has_value()) {
    const double pending = *job->last_progress;
    job->last_progress.reset();
    xh_mc_media_compression_flutter_api_on_progress(
        job->flutter_api, pending, nullptr, on_progress_done, nullptr);
  }
  xh_mc_media_compression_flutter_api_on_video_completed(
      job->flutter_api, result, nullptr, on_video_completed_done, nullptr);
}

static void SendError(const std::shared_ptr<Job>& job, const char* code,
                      const char* message) {
  if (job->closed || job->terminal || job->flutter_api == nullptr) {
    return;
  }
  job->terminal = true;
  job->last_progress.reset();
  xh_mc_media_compression_flutter_api_on_error(
      job->flutter_api, code != nullptr ? code : "encode",
      message != nullptr ? message : "Native error", nullptr, on_error_done,
      nullptr);
}

static XhMcMediaCompressionHostApiCreateJobResponse* handle_create_job(
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  const int64_t id = self->next_id++;
  auto job = std::make_shared<Job>();
  job->id = id;
  const std::string suffix = "job_" + std::to_string(id);
  job->flutter_api =
      xh_mc_media_compression_flutter_api_new(self->messenger, suffix.c_str());
  self->jobs->emplace(id, job);
  return xh_mc_media_compression_host_api_create_job_response_new(id);
}

static void handle_query_image(
    XhMcMediaCompressionHostApiResponseHandle* response_handle, gpointer) {
  g_object_ref(response_handle);
  std::thread([response_handle]() {
    XhMcImageCapabilitiesMsg* caps = query_image_capabilities_vips();
    PostToMain([response_handle, caps]() {
      xh_mc_media_compression_host_api_respond_query_image_capabilities(
          response_handle, caps);
      g_object_unref(caps);
      g_object_unref(response_handle);
    });
  }).detach();
}

static void handle_start_image(
    int64_t id, XhMcSourceMsg* source, XhMcDestinationMsg* destination,
    XhMcImageOptionsMsg* options,
    XhMcMediaCompressionHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  std::shared_ptr<Job> job = JobOf(self, id);
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
  std::string output_path;
  if (xh_mc_destination_msg_get_kind(destination) == 1) {
    const gchar* path = xh_mc_destination_msg_get_path(destination);
    if (path != nullptr) output_path = path;
  }
  std::thread([job, source, destination, options, output_path]() {
    char* code = nullptr;
    char* message = nullptr;
    XhMcImageCompressResultMsg* result = nullptr;
    if (job->cancelled.load()) {
      code = g_strdup("cancelled");
      message = g_strdup("Cancelled");
    } else {
      PostToMain([job]() {
        if (!job->cancelled.load()) {
          SendProgress(job, 0.25);
        }
      });
      result =
          compress_image_vips(source, destination, options, &code, &message);
    }
    g_object_unref(source);
    g_object_unref(destination);
    g_object_unref(options);
    PostToMain([job, result, code, message, output_path]() {
      if (job->cancelled.load()) {
        if (!output_path.empty()) g_remove(output_path.c_str());
        SendError(job, "cancelled", "Cancelled");
        if (result != nullptr) g_object_unref(result);
      } else if (result != nullptr) {
        SendProgress(job, 1.0);
        SendImageCompleted(job, result);
        g_object_unref(result);
      } else {
        SendError(job, code != nullptr ? code : "encode",
                  message != nullptr ? message : "Image compress failed");
      }
      g_free(code);
      g_free(message);
    });
  }).detach();
}

static void handle_query_video(
    XhMcMediaCompressionHostApiResponseHandle* response_handle, gpointer) {
  g_object_ref(response_handle);
  std::thread([response_handle]() {
    XhMcVideoCapabilitiesMsg* caps = query_video_capabilities_gst();
    PostToMain([response_handle, caps]() {
      xh_mc_media_compression_host_api_respond_query_video_capabilities(
          response_handle, caps);
      g_object_unref(caps);
      g_object_unref(response_handle);
    });
  }).detach();
}

static void handle_start_video(
    int64_t id, const gchar* input_path, const gchar* output_path,
    XhMcVideoOptionsMsg* options,
    XhMcMediaCompressionHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  std::shared_ptr<Job> job = JobOf(self, id);
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
  std::thread([job, in, out, options]() {
    compress_video_gst(
        in, out, options, &job->cancelled,
        [job](double value) {
          PostToMain([job, value]() {
            if (!job->cancelled.load()) {
              SendProgress(job, value);
            }
          });
        },
        [job, out](XhMcVideoCompressResultMsg* result) {
          PostToMain([job, result, out]() {
            if (job->cancelled.load()) {
              g_remove(out.c_str());
              SendError(job, "cancelled", "Cancelled");
            } else {
              SendProgress(job, 1.0);
              SendVideoCompleted(job, result);
            }
            if (result != nullptr) {
              g_object_unref(result);
            }
          });
        },
        [job](const char* code, const char* message) {
          std::string c = code != nullptr ? code : "encode";
          std::string m = message != nullptr ? message : "Video compress failed";
          PostToMain([job, c, m]() {
            SendError(job, c.c_str(), m.c_str());
          });
        });
    g_object_unref(options);
    // Drop the worker's Job reference on the GLib main thread.
    PostToMain([job]() {});
  }).detach();
}

static XhMcMediaCompressionHostApiCancelJobResponse* handle_cancel(
    int64_t id, gpointer user_data) {
  auto* self = XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN(user_data);
  std::shared_ptr<Job> job = JobOf(self, id);
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
  auto it = self->jobs->find(id);
  if (it != self->jobs->end()) {
    it->second->cancelled.store(true);
    it->second->closed = true;
    self->jobs->erase(it);
  }
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
  if (self->jobs != nullptr) {
    for (auto& entry : *self->jobs) {
      entry.second->cancelled.store(true);
      entry.second->closed = true;
    }
    delete self->jobs;
    self->jobs = nullptr;
  }
  G_OBJECT_CLASS(xue_hua_media_compression_linux_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_media_compression_linux_plugin_class_init(
    XueHuaMediaCompressionLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_media_compression_linux_plugin_dispose;
}

static void xue_hua_media_compression_linux_plugin_init(
    XueHuaMediaCompressionLinuxPlugin* self) {
  self->jobs = new std::map<int64_t, std::shared_ptr<Job>>();
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

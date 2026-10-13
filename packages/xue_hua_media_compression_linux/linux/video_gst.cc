#include "video_gst.h"

#include <glib/gstdio.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <gst/video/video.h>

#include <algorithm>
#include <mutex>
#include <vector>

namespace {

// Encoders in priority order: hardware first, software fallback last.
struct EncoderSpec {
  const char* factory;
  bool hardware;
  // Property names; nullptr when the element has no equivalent.
  const char* bitrate_prop;
  bool bitrate_in_kbps;
  const char* gop_prop;
};

const std::vector<EncoderSpec>& H264Encoders() {
  static const std::vector<EncoderSpec> kList = {
      {"vah264enc", true, "bitrate", true, "key-int-max"},
      {"vah264lpenc", true, "bitrate", true, "key-int-max"},
      {"vaapih264enc", true, "bitrate", true, "keyframe-period"},
      {"nvh264enc", true, "bitrate", true, "gop-size"},
      {"x264enc", false, "bitrate", true, "key-int-max"},
      {"openh264enc", false, "bitrate", false, "gop-size"},
  };
  return kList;
}

const std::vector<EncoderSpec>& H265Encoders() {
  static const std::vector<EncoderSpec> kList = {
      {"vah265enc", true, "bitrate", true, "key-int-max"},
      {"vah265lpenc", true, "bitrate", true, "key-int-max"},
      {"vaapih265enc", true, "bitrate", true, "keyframe-period"},
      {"nvh265enc", true, "bitrate", true, "gop-size"},
      {"x265enc", false, "bitrate", true, "key-int-max"},
  };
  return kList;
}

bool HasFactory(const char* name) {
  GstElementFactory* f = gst_element_factory_find(name);
  if (f == nullptr) return false;
  gst_object_unref(f);
  return true;
}

// Initialise GStreamer once and make sure FFmpeg-based elements (gst-libav:
// avdec_*, avenc_*, avdemux_*, avmux_*) are never auto-plugged, even when the
// gst-libav package happens to be installed on the system.
void EnsureGstInit() {
  static std::once_flag once;
  std::call_once(once, []() {
    gst_init(nullptr, nullptr);
    GstRegistry* registry = gst_registry_get();
    GstPlugin* libav = gst_registry_find_plugin(registry, "libav");
    if (libav != nullptr) {
      GList* features = gst_registry_get_feature_list_by_plugin(registry, "libav");
      for (GList* l = features; l != nullptr; l = l->next) {
        gst_plugin_feature_set_rank(GST_PLUGIN_FEATURE(l->data), GST_RANK_NONE);
      }
      gst_plugin_feature_list_free(features);
      gst_object_unref(libav);
    }
  });
}

// decodebin: refuse any FFmpeg-backed factory as a last line of defence.
GValueArray* NoFfmpegAutoplugSort(GstElement*, GstPad*, GstCaps*,
                                  GValueArray* factories, gpointer) {
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  GValueArray* result = g_value_array_new(factories->n_values);
  for (guint i = 0; i < factories->n_values; ++i) {
    GValue* v = g_value_array_get_nth(factories, i);
    auto* f = GST_ELEMENT_FACTORY(g_value_get_object(v));
    GstPlugin* plugin = gst_plugin_feature_get_plugin(GST_PLUGIN_FEATURE(f));
    bool is_libav = false;
    if (plugin != nullptr) {
      is_libav = g_strcmp0(gst_plugin_get_name(plugin), "libav") == 0;
      gst_object_unref(plugin);
    }
    if (!is_libav) g_value_array_append(result, v);
  }
  G_GNUC_END_IGNORE_DEPRECATIONS
  return result;
}

void SetIfExists(GstElement* e, const char* prop, guint value) {
  if (prop == nullptr) return;
  GParamSpec* spec = g_object_class_find_property(G_OBJECT_GET_CLASS(e), prop);
  if (spec == nullptr) return;
  GValue v = G_VALUE_INIT;
  g_value_init(&v, G_TYPE_UINT);
  g_value_set_uint(&v, value);
  GValue converted = G_VALUE_INIT;
  g_value_init(&converted, spec->value_type);
  if (g_value_transform(&v, &converted) &&
      !g_param_value_validate(spec, &converted)) {
    g_object_set_property(G_OBJECT(e), prop, &converted);
  }
  g_value_unset(&converted);
  g_value_unset(&v);
}

const char* AacEncoder() {
  for (const char* name : {"fdkaacenc", "voaacenc"}) {
    if (HasFactory(name)) return name;
  }
  return nullptr;
}

struct ProbeInfo {
  int width = 0;
  int height = 0;
  bool has_audio = false;
  GstClockTime duration = GST_CLOCK_TIME_NONE;
};

bool Probe(const std::string& uri, ProbeInfo* info, std::string* err) {
  GError* error = nullptr;
  GstDiscoverer* disc = gst_discoverer_new(30 * GST_SECOND, &error);
  if (disc == nullptr) {
    *err = error ? error->message : "discoverer failed";
    g_clear_error(&error);
    return false;
  }
  GstDiscovererInfo* di = gst_discoverer_discover_uri(disc, uri.c_str(), &error);
  bool ok = false;
  if (di != nullptr &&
      gst_discoverer_info_get_result(di) == GST_DISCOVERER_OK) {
    info->duration = gst_discoverer_info_get_duration(di);
    GList* videos = gst_discoverer_info_get_video_streams(di);
    if (videos != nullptr) {
      auto* v = GST_DISCOVERER_VIDEO_INFO(videos->data);
      info->width = static_cast<int>(gst_discoverer_video_info_get_width(v));
      info->height = static_cast<int>(gst_discoverer_video_info_get_height(v));
      ok = info->width > 0 && info->height > 0;
      if (!ok) *err = "Video stream has unknown dimensions";
    } else {
      *err = "No video stream";
    }
    gst_discoverer_stream_info_list_free(videos);
    GList* audios = gst_discoverer_info_get_audio_streams(di);
    info->has_audio = audios != nullptr;
    gst_discoverer_stream_info_list_free(audios);
  } else {
    *err = error ? error->message : "Unable to read input";
  }
  g_clear_error(&error);
  if (di) g_object_unref(di);
  g_object_unref(disc);
  return ok;
}

enum class RunResult { kOk, kFailed, kCancelled };

RunResult RunPipeline(const std::string& description,
                      const std::string& input_path,
                      const std::string& output_path, const EncoderSpec& spec,
                      int64_t bitrate, int64_t gop, std::atomic<bool>* cancelled,
                      const std::function<void(double)>& on_progress,
                      std::string* err) {
  GError* error = nullptr;
  GstElement* pipeline = gst_parse_launch(description.c_str(), &error);
  if (pipeline == nullptr || error != nullptr) {
    *err = error ? error->message : "Failed to build pipeline";
    g_clear_error(&error);
    if (pipeline) gst_object_unref(pipeline);
    return RunResult::kFailed;
  }
  GstBin* bin = GST_BIN(pipeline);
  GstElement* src = gst_bin_get_by_name(bin, "src");
  GstElement* sink = gst_bin_get_by_name(bin, "sink");
  GstElement* dec = gst_bin_get_by_name(bin, "dec");
  GstElement* enc = gst_bin_get_by_name(bin, "enc");
  g_object_set(src, "location", input_path.c_str(), nullptr);
  g_object_set(sink, "location", output_path.c_str(), nullptr);
  g_signal_connect(dec, "autoplug-sort", G_CALLBACK(NoFfmpegAutoplugSort),
                   nullptr);
  if (bitrate > 0) {
    const int64_t value = spec.bitrate_in_kbps ? std::max<int64_t>(1, bitrate / 1000)
                                               : bitrate;
    SetIfExists(enc, spec.bitrate_prop,
                static_cast<guint>(std::min<int64_t>(value, G_MAXUINT)));
  }
  if (gop > 0) SetIfExists(enc, spec.gop_prop, static_cast<guint>(gop));
  gst_object_unref(src);
  gst_object_unref(sink);
  gst_object_unref(dec);
  gst_object_unref(enc);

  RunResult result = RunResult::kFailed;
  if (gst_element_set_state(pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    *err = "Unable to start pipeline";
  } else {
    GstBus* bus = gst_element_get_bus(pipeline);
    double last = 0;
    bool done = false;
    while (!done) {
      if (cancelled && cancelled->load()) {
        result = RunResult::kCancelled;
        break;
      }
      GstMessage* msg = gst_bus_timed_pop_filtered(
          bus, 100 * GST_MSECOND,
          static_cast<GstMessageType>(GST_MESSAGE_ERROR | GST_MESSAGE_EOS));
      if (msg == nullptr) {
        gint64 pos = 0, dur = 0;
        if (gst_element_query_position(pipeline, GST_FORMAT_TIME, &pos) &&
            gst_element_query_duration(pipeline, GST_FORMAT_TIME, &dur) &&
            dur > 0 && pos > 0) {
          const double p = std::min(0.99, static_cast<double>(pos) / dur);
          if (p > last) {
            last = p;
            on_progress(p);
          }
        }
        continue;
      }
      if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS) {
        result = RunResult::kOk;
      } else {
        GError* e = nullptr;
        gchar* dbg = nullptr;
        gst_message_parse_error(msg, &e, &dbg);
        *err = e ? e->message : "Pipeline error";
        g_clear_error(&e);
        g_free(dbg);
      }
      gst_message_unref(msg);
      done = true;
    }
    gst_object_unref(bus);
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  return result;
}

}  // namespace

XhMcVideoCapabilitiesMsg* query_video_capabilities_gst() {
  EnsureGstInit();
  g_autoptr(FlValue) codecs = fl_value_new_list();
  const char* encoder_name = nullptr;
  bool hw = false;
  for (auto [codec, list] : {std::make_pair("h264", &H264Encoders()),
                             std::make_pair("h265", &H265Encoders())}) {
    for (const auto& spec : *list) {
      if (HasFactory(spec.factory)) {
        fl_value_append_take(codecs, fl_value_new_string(codec));
        hw = hw || spec.hardware;
        break;
      }
    }
  }
  if (fl_value_get_length(codecs) > 0) {
    encoder_name = hw ? "GStreamerHW" : "GStreamerSoftware";
  }
  return xh_mc_video_capabilities_msg_new(encoder_name, codecs, FALSE);
}

void compress_video_gst(
    const std::string& input_path, const std::string& output_path,
    XhMcVideoOptionsMsg* options, std::atomic<bool>* cancelled,
    const std::function<void(double)>& on_progress,
    const std::function<void(FlValue*)>& on_completed,
    const std::function<void(const char*, const char*)>& on_error) {
  if (g_str_has_prefix(input_path.c_str(), "content://")) {
    on_error("unsupported", "content:// is Android-only");
    return;
  }
  if (!g_file_test(input_path.c_str(), G_FILE_TEST_IS_REGULAR)) {
    on_error("notFound", "Unable to open input");
    return;
  }
  EnsureGstInit();

  const char* codec_name = xh_mc_video_options_msg_get_codec(options);
  const bool hevc = g_strcmp0(codec_name, "h265") == 0;
  const auto& candidates = hevc ? H265Encoders() : H264Encoders();
  std::vector<const EncoderSpec*> available;
  for (const auto& spec : candidates) {
    if (HasFactory(spec.factory)) available.push_back(&spec);
  }
  if (available.empty()) {
    on_error("hardwareUnavailable",
             hevc ? "No H.265 encoder (va/vaapi/nvcodec/x265) found"
                  : "No H.264 encoder (va/vaapi/nvcodec/x264/openh264) found");
    return;
  }

  gchar* uri = gst_filename_to_uri(input_path.c_str(), nullptr);
  ProbeInfo info;
  std::string err;
  const bool probed = uri != nullptr && Probe(uri, &info, &err);
  g_free(uri);
  if (!probed) {
    on_error("decode", err.empty() ? "Unable to probe input" : err.c_str());
    return;
  }

  int out_w = info.width;
  int out_h = info.height;
  int64_t* max_dim = xh_mc_video_options_msg_get_max_dimension(options);
  if (max_dim != nullptr && *max_dim > 0) {
    const int longest = std::max(out_w, out_h);
    if (longest > *max_dim) {
      const double scale = static_cast<double>(*max_dim) / longest;
      out_w = static_cast<int>(out_w * scale);
      out_h = static_cast<int>(out_h * scale);
    }
  }
  // Encoders need even dimensions for 4:2:0.
  out_w = std::max(2, out_w / 2 * 2);
  out_h = std::max(2, out_h / 2 * 2);

  gchar* caps = g_strdup_printf("video/x-raw,width=%d,height=%d,pixel-aspect-ratio=1/1",
                                out_w, out_h);
  std::string video_caps = caps;
  g_free(caps);
  int64_t* fps = xh_mc_video_options_msg_get_fps(options);
  std::string rate;
  if (fps != nullptr && *fps > 0) {
    video_caps += ",framerate=" + std::to_string(*fps) + "/1";
    rate = "videorate ! ";
  }
  int64_t* gop_ptr = xh_mc_video_options_msg_get_keyframe_interval(options);
  const int64_t gop = gop_ptr != nullptr ? *gop_ptr : 0;
  const int64_t bitrate = xh_mc_video_options_msg_get_bitrate(options);

  const char* aac = AacEncoder();
  const bool with_audio =
      xh_mc_video_options_msg_get_keep_audio(options) && info.has_audio &&
      aac != nullptr;

  gchar* dir = g_path_get_dirname(output_path.c_str());
  g_mkdir_with_parents(dir, 0755);
  g_free(dir);

  const char* parser = hevc ? "h265parse" : "h264parse";
  std::string last_err;
  for (const EncoderSpec* spec : available) {
    std::string desc =
        "filesrc name=src ! decodebin name=dec "
        "dec. ! queue ! videoconvert ! videoscale ! " + rate +
        "capsfilter caps=\"" + video_caps + "\" ! videoconvert ! " +
        // 8-bit 4:2:0 for maximum player compatibility (HW: NV12).
        "video/x-raw,format=" + (spec->hardware ? "NV12" : "I420") + " ! " +
        spec->factory + " name=enc ! " + parser +
        " ! video/x-" + (hevc ? "h265" : "h264") +
        ",stream-format=" + (hevc ? "hvc1" : "avc") +
        " ! mp4mux name=mux faststart=true ! filesink name=sink";
    if (with_audio) {
      desc += std::string(" dec. ! queue ! audioconvert ! audioresample ! ") +
              aac + " ! aacparse ! mux.";
    }
    std::string run_err;
    const RunResult r = RunPipeline(desc, input_path, output_path, *spec,
                                    bitrate, gop, cancelled, on_progress,
                                    &run_err);
    if (r == RunResult::kCancelled) {
      g_remove(output_path.c_str());
      on_error("cancelled", "Cancelled");
      return;
    }
    if (r == RunResult::kOk) {
      GStatBuf st = {};
      int64_t size = 0;
      if (g_stat(output_path.c_str(), &st) == 0) size = st.st_size;
      on_progress(1.0);
      FlValue* map = fl_value_new_map();
      fl_value_set_string_take(map, "outputPath",
                               fl_value_new_string(output_path.c_str()));
      fl_value_set_string_take(map, "sizeBytes", fl_value_new_int(size));
      gchar* name = g_strdup_printf("GStreamer:%s", spec->factory);
      fl_value_set_string_take(map, "encoderName", fl_value_new_string(name));
      g_free(name);
      fl_value_set_string_take(map, "codec",
                               fl_value_new_string(hevc ? "h265" : "h264"));
      fl_value_set_string_take(map, "width", fl_value_new_int(out_w));
      fl_value_set_string_take(map, "height", fl_value_new_int(out_h));
      on_completed(map);
      return;
    }
    // Runtime failure (e.g. HW encoder present but unusable): try the next.
    g_remove(output_path.c_str());
    last_err = std::string(spec->factory) + ": " + run_err;
    g_warning("xue_hua_media_compression: %s, trying next encoder",
              last_err.c_str());
  }
  on_error("encode", last_err.c_str());
}

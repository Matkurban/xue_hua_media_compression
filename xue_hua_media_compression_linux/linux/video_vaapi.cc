#include "video_vaapi.h"

#include <glib/gstdio.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
}

#include <algorithm>
#include <memory>

namespace {

struct AvDeleter {
  void operator()(AVFormatContext* c) const {
    if (c) avformat_close_input(&c);
  }
};

enum AVPixelFormat GetVaapiFormat(AVCodecContext*,
                                  const enum AVPixelFormat* pix_fmts) {
  for (const enum AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; ++p) {
    if (*p == AV_PIX_FMT_VAAPI) {
      return *p;
    }
  }
  return AV_PIX_FMT_NONE;
}

bool EncoderAvailable(const char* name) {
  return avcodec_find_encoder_by_name(name) != nullptr;
}

}  // namespace

XhMcVideoCapabilitiesMsg* query_video_capabilities_vaapi() {
  AVBufferRef* hw = nullptr;
  const int rc = av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VAAPI, nullptr,
                                        nullptr, 0);
  g_autoptr(FlValue) codecs = fl_value_new_list();
  const char* encoder_name = nullptr;
  if (rc == 0) {
    if (EncoderAvailable("h264_vaapi")) {
      fl_value_append_take(codecs, fl_value_new_string("h264"));
    }
    if (EncoderAvailable("hevc_vaapi")) {
      fl_value_append_take(codecs, fl_value_new_string("h265"));
    }
    if (fl_value_get_length(codecs) > 0) {
      encoder_name = "FFmpegVAAPI";
    }
    av_buffer_unref(&hw);
  }
  return xh_mc_video_capabilities_msg_new(encoder_name, codecs, FALSE);
}

void compress_video_vaapi(
    const std::string& input_path, const std::string& output_path,
    XhMcVideoOptionsMsg* options, std::atomic<bool>* cancelled,
    const std::function<void(double)>& on_progress,
    const std::function<void(FlValue*)>& on_completed,
    const std::function<void(const char*, const char*)>& on_error) {
  if (g_str_has_prefix(input_path.c_str(), "content://")) {
    on_error("unsupported", "content:// is Android-only");
    return;
  }
  const char* codec_name = xh_mc_video_options_msg_get_codec(options);
  const char* encoder_name =
      g_strcmp0(codec_name, "h265") == 0 ? "hevc_vaapi" : "h264_vaapi";
  const AVCodec* encoder = avcodec_find_encoder_by_name(encoder_name);
  if (encoder == nullptr) {
    on_error("hardwareUnavailable", "VAAPI encoder not found");
    return;
  }

  AVBufferRef* hw_device = nullptr;
  if (av_hwdevice_ctx_create(&hw_device, AV_HWDEVICE_TYPE_VAAPI, nullptr,
                             nullptr, 0) < 0) {
    on_error("hardwareUnavailable", "Unable to open VAAPI device");
    return;
  }

  AVFormatContext* input_fmt = nullptr;
  if (avformat_open_input(&input_fmt, input_path.c_str(), nullptr, nullptr) <
      0) {
    av_buffer_unref(&hw_device);
    on_error("notFound", "Unable to open input");
    return;
  }
  avformat_find_stream_info(input_fmt, nullptr);
  const int video_index =
      av_find_best_stream(input_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
  if (video_index < 0) {
    avformat_close_input(&input_fmt);
    av_buffer_unref(&hw_device);
    on_error("decode", "No video stream");
    return;
  }
  AVStream* in_stream = input_fmt->streams[video_index];
  const AVCodec* decoder = avcodec_find_decoder(in_stream->codecpar->codec_id);
  AVCodecContext* dec_ctx = avcodec_alloc_context3(decoder);
  avcodec_parameters_to_context(dec_ctx, in_stream->codecpar);
  dec_ctx->hw_device_ctx = av_buffer_ref(hw_device);
  dec_ctx->get_format = GetVaapiFormat;
  if (avcodec_open2(dec_ctx, decoder, nullptr) < 0) {
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&input_fmt);
    av_buffer_unref(&hw_device);
    on_error("hardwareUnavailable", "VAAPI decode is not available for this file");
    return;
  }

  int out_w = dec_ctx->width;
  int out_h = dec_ctx->height;
  int64_t* max_dim = xh_mc_video_options_msg_get_max_dimension(options);
  if (max_dim != nullptr && *max_dim > 0) {
    const int longest = std::max(out_w, out_h);
    if (longest > *max_dim) {
      const double scale = static_cast<double>(*max_dim) / longest;
      out_w = std::max(2, static_cast<int>(out_w * scale) / 2 * 2);
      out_h = std::max(2, static_cast<int>(out_h * scale) / 2 * 2);
    }
  }

  AVCodecContext* enc_ctx = avcodec_alloc_context3(encoder);
  enc_ctx->width = out_w;
  enc_ctx->height = out_h;
  enc_ctx->pix_fmt = AV_PIX_FMT_VAAPI;
  enc_ctx->time_base = av_inv_q(in_stream->avg_frame_rate.num
                                    ? in_stream->avg_frame_rate
                                    : AVRational{30, 1});
  enc_ctx->framerate = in_stream->avg_frame_rate.num ? in_stream->avg_frame_rate
                                                     : AVRational{30, 1};
  int64_t* fps = xh_mc_video_options_msg_get_fps(options);
  if (fps != nullptr && *fps > 0) {
    enc_ctx->framerate = AVRational{static_cast<int>(*fps), 1};
    enc_ctx->time_base = av_inv_q(enc_ctx->framerate);
  }
  enc_ctx->bit_rate = xh_mc_video_options_msg_get_bitrate(options);
  int64_t* gop = xh_mc_video_options_msg_get_keyframe_interval(options);
  if (gop != nullptr && *gop > 0) {
    enc_ctx->gop_size = static_cast<int>(*gop);
  }
  enc_ctx->hw_device_ctx = av_buffer_ref(hw_device);
  enc_ctx->hw_frames_ctx = av_buffer_ref(dec_ctx->hw_frames_ctx);
  if (avcodec_open2(enc_ctx, encoder, nullptr) < 0) {
    avcodec_free_context(&enc_ctx);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&input_fmt);
    av_buffer_unref(&hw_device);
    on_error("hardwareUnavailable", "Unable to open VAAPI encoder");
    return;
  }

  gchar* dir = g_path_get_dirname(output_path.c_str());
  g_mkdir_with_parents(dir, 0755);
  g_free(dir);

  AVFormatContext* output_fmt = nullptr;
  avformat_alloc_output_context2(&output_fmt, nullptr, "mp4",
                                 output_path.c_str());
  AVStream* out_stream = avformat_new_stream(output_fmt, nullptr);
  avcodec_parameters_from_context(out_stream->codecpar, enc_ctx);
  out_stream->time_base = enc_ctx->time_base;
  if (!(output_fmt->oformat->flags & AVFMT_NOFILE)) {
    avio_open(&output_fmt->pb, output_path.c_str(), AVIO_FLAG_WRITE);
  }
  avformat_write_header(output_fmt, nullptr);

  AVFilterGraph* graph = avfilter_graph_alloc();
  const AVFilter* buffersrc = avfilter_get_by_name("buffer");
  const AVFilter* buffersink = avfilter_get_by_name("buffersink");
  const AVFilter* scale = avfilter_get_by_name("scale_vaapi");
  AVFilterContext* src_ctx = nullptr;
  AVFilterContext* sink_ctx = nullptr;
  AVFilterContext* scale_ctx = nullptr;
  char args[256];
  snprintf(args, sizeof(args),
           "video_size=%dx%d:pix_fmt=vaapi:time_base=%d/%d:pixel_aspect=1/1",
           dec_ctx->width, dec_ctx->height, in_stream->time_base.num,
           in_stream->time_base.den);
  avfilter_graph_create_filter(&src_ctx, buffersrc, "in", args, nullptr, graph);
  avfilter_graph_create_filter(&sink_ctx, buffersink, "out", nullptr, nullptr,
                               graph);
  if (scale != nullptr && (out_w != dec_ctx->width || out_h != dec_ctx->height)) {
    char scale_args[64];
    snprintf(scale_args, sizeof(scale_args), "w=%d:h=%d", out_w, out_h);
    avfilter_graph_create_filter(&scale_ctx, scale, "scale", scale_args, nullptr,
                                 graph);
    avfilter_link(src_ctx, 0, scale_ctx, 0);
    avfilter_link(scale_ctx, 0, sink_ctx, 0);
  } else {
    avfilter_link(src_ctx, 0, sink_ctx, 0);
  }
  if (avfilter_graph_config(graph, nullptr) < 0) {
    avfilter_graph_free(&graph);
    avformat_free_context(output_fmt);
    avcodec_free_context(&enc_ctx);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&input_fmt);
    av_buffer_unref(&hw_device);
    on_error("encode", "Failed to configure VAAPI filter graph");
    return;
  }

  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* filt = av_frame_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  const int64_t duration = in_stream->duration > 0
                               ? in_stream->duration
                               : (input_fmt->duration > 0
                                      ? av_rescale_q(input_fmt->duration,
                                                     AV_TIME_BASE_Q,
                                                     in_stream->time_base)
                                      : 0);

  auto fail = [&](const char* c, const char* m) {
    av_packet_free(&packet);
    av_frame_free(&frame);
    av_frame_free(&filt);
    av_packet_free(&enc_pkt);
    avfilter_graph_free(&graph);
    if (output_fmt) {
      av_write_trailer(output_fmt);
      if (!(output_fmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&output_fmt->pb);
      avformat_free_context(output_fmt);
    }
    avcodec_free_context(&enc_ctx);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&input_fmt);
    av_buffer_unref(&hw_device);
    on_error(c, m);
  };

  while (av_read_frame(input_fmt, packet) >= 0) {
    if (cancelled && cancelled->load()) {
      av_packet_unref(packet);
      fail("cancelled", "Cancelled");
      return;
    }
    if (packet->stream_index != video_index) {
      av_packet_unref(packet);
      continue;
    }
    if (avcodec_send_packet(dec_ctx, packet) < 0) {
      av_packet_unref(packet);
      fail("decode", "Decoder send failed");
      return;
    }
    av_packet_unref(packet);
    while (avcodec_receive_frame(dec_ctx, frame) == 0) {
      if (av_buffersrc_add_frame_flags(src_ctx, frame, AV_BUFFERSRC_FLAG_KEEP_REF) <
          0) {
        av_frame_unref(frame);
        fail("encode", "Filter source failed");
        return;
      }
      av_frame_unref(frame);
      while (av_buffersink_get_frame(sink_ctx, filt) >= 0) {
        if (avcodec_send_frame(enc_ctx, filt) < 0) {
          av_frame_unref(filt);
          fail("encode", "Encoder send failed");
          return;
        }
        av_frame_unref(filt);
        while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
          av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_stream->time_base);
          enc_pkt->stream_index = 0;
          if (duration > 0 && enc_pkt->pts > 0) {
            on_progress(std::min(1.0, enc_pkt->pts / static_cast<double>(duration)));
          }
          av_interleaved_write_frame(output_fmt, enc_pkt);
          av_packet_unref(enc_pkt);
        }
      }
    }
  }

  avcodec_send_frame(enc_ctx, nullptr);
  while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
    av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_stream->time_base);
    enc_pkt->stream_index = 0;
    av_interleaved_write_frame(output_fmt, enc_pkt);
    av_packet_unref(enc_pkt);
  }
  av_write_trailer(output_fmt);
  if (!(output_fmt->oformat->flags & AVFMT_NOFILE)) {
    avio_closep(&output_fmt->pb);
  }

  GStatBuf st = {};
  int64_t size = 0;
  if (g_stat(output_path.c_str(), &st) == 0) size = st.st_size;
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "outputPath",
                           fl_value_new_string(output_path.c_str()));
  fl_value_set_string_take(map, "sizeBytes", fl_value_new_int(size));
  fl_value_set_string_take(map, "encoderName",
                           fl_value_new_string("FFmpegVAAPI"));
  fl_value_set_string_take(map, "codec", fl_value_new_string(codec_name));
  fl_value_set_string_take(map, "width", fl_value_new_int(out_w));
  fl_value_set_string_take(map, "height", fl_value_new_int(out_h));

  av_packet_free(&packet);
  av_frame_free(&frame);
  av_frame_free(&filt);
  av_packet_free(&enc_pkt);
  avfilter_graph_free(&graph);
  avformat_free_context(output_fmt);
  avcodec_free_context(&enc_ctx);
  avcodec_free_context(&dec_ctx);
  avformat_close_input(&input_fmt);
  av_buffer_unref(&hw_device);
  on_completed(map);
}

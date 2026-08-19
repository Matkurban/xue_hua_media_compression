#ifndef FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>

#include "event_stream.h"
#include "main_thread_dispatcher.h"
#include "messages.g.h"
#include "video_transcoder.h"

namespace xue_hua_media_compression {

class XueHuaMediaCompressionWindowsPlugin : public flutter::Plugin,
                                            public MediaCompressionHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit XueHuaMediaCompressionWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar);
  virtual ~XueHuaMediaCompressionWindowsPlugin();

  XueHuaMediaCompressionWindowsPlugin(
      const XueHuaMediaCompressionWindowsPlugin&) = delete;
  XueHuaMediaCompressionWindowsPlugin& operator=(
      const XueHuaMediaCompressionWindowsPlugin&) = delete;

  ErrorOr<int64_t> CreateJob() override;
  ErrorOr<ImageCapabilitiesMsg> QueryImageCapabilities() override;
  void StartImageCompress(
      int64_t id, const SourceMsg& source, const DestinationMsg& destination,
      const ImageOptionsMsg& options,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  ErrorOr<VideoCapabilitiesMsg> QueryVideoCapabilities() override;
  void StartVideoCompress(
      int64_t id, const std::string& input_path, const std::string& output_path,
      const VideoOptionsMsg& options,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  std::optional<FlutterError> CancelJob(int64_t id) override;
  std::optional<FlutterError> DisposeJob(int64_t id) override;

 private:
  struct Job {
    std::shared_ptr<EventStream> events;
    std::unique_ptr<VideoJob> video;
    bool started = false;
  };

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  std::map<int64_t, std::unique_ptr<Job>> jobs_;
  int64_t next_id_ = 1;
};

}  // namespace xue_hua_media_compression

#endif  // FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_

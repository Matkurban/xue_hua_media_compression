#ifndef FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

#include "main_thread_dispatcher.h"
#include "messages.g.h"

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
  void QueryImageCapabilities(
      std::function<void(ErrorOr<ImageCapabilitiesMsg> reply)> result) override;
  void StartImageCompress(
      int64_t id, const SourceMsg& source, const DestinationMsg& destination,
      const ImageOptionsMsg& options,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void QueryVideoCapabilities(
      std::function<void(ErrorOr<VideoCapabilitiesMsg> reply)> result) override;
  void StartVideoCompress(
      int64_t id, const std::string& input_path, const std::string& output_path,
      const VideoOptionsMsg& options,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  std::optional<FlutterError> CancelJob(int64_t id) override;
  std::optional<FlutterError> DisposeJob(int64_t id) override;

 private:
  struct Job {
    std::unique_ptr<MediaCompressionFlutterApi> flutter_api;
    std::shared_ptr<std::atomic<bool>> cancelled =
        std::make_shared<std::atomic<bool>>(false);
    std::atomic<bool> output_opened{false};
    std::string output_path;
    bool started = false;
    bool closed = false;
    bool terminal = false;
    bool sent_positive = false;
    uint64_t last_progress_sent_ms = 0;
    std::optional<double> last_progress;
  };

  static void SendProgress(const std::shared_ptr<Job>& job, double value);
  static void SendImageCompleted(const std::shared_ptr<Job>& job,
                                 const ImageCompressResultMsg& result);
  static void SendVideoCompleted(const std::shared_ptr<Job>& job,
                                 const VideoCompressResultMsg& result);
  static void SendError(const std::shared_ptr<Job>& job,
                        const std::string& code, const std::string& message);
  static void DeleteJobOutput(const std::shared_ptr<Job>& job);
  static void ReleaseOnPlatform(
      const std::shared_ptr<MainThreadDispatcher>& dispatcher,
      const std::shared_ptr<Job>& job);

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  std::map<int64_t, std::shared_ptr<Job>> jobs_;
  int64_t next_id_ = 1;
};

}  // namespace xue_hua_media_compression

#endif  // FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_WINDOWS_PLUGIN_H_

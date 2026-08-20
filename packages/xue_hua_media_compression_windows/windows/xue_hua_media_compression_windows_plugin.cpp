#include "xue_hua_media_compression_windows_plugin.h"

#include <windows.h>

#include <thread>

#include "image_wic.h"

namespace xue_hua_media_compression {

void XueHuaMediaCompressionWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin =
      std::make_unique<XueHuaMediaCompressionWindowsPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

XueHuaMediaCompressionWindowsPlugin::XueHuaMediaCompressionWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      dispatcher_(std::make_shared<MainThreadDispatcher>()) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  MediaCompressionHostApi::SetUp(registrar->messenger(), this);
}

XueHuaMediaCompressionWindowsPlugin::~XueHuaMediaCompressionWindowsPlugin() {
  MediaCompressionHostApi::SetUp(registrar_->messenger(), nullptr);
}

ErrorOr<int64_t> XueHuaMediaCompressionWindowsPlugin::CreateJob() {
  const int64_t id = next_id_++;
  auto job = std::make_unique<Job>();
  job->events =
      std::make_shared<EventStream>(registrar_->messenger(), id);
  jobs_[id] = std::move(job);
  return id;
}

ErrorOr<ImageCapabilitiesMsg>
XueHuaMediaCompressionWindowsPlugin::QueryImageCapabilities() {
  try {
    return QueryImageCapabilitiesWic();
  } catch (const FlutterError& error) {
    return error;
  }
}

void XueHuaMediaCompressionWindowsPlugin::StartImageCompress(
    int64_t id, const SourceMsg& source, const DestinationMsg& destination,
    const ImageOptionsMsg& options,
    std::function<void(std::optional<FlutterError> reply)> result) {
  auto it = jobs_.find(id);
  if (it == jobs_.end()) {
    result(FlutterError("instanceNotFound", "No job"));
    return;
  }
  if (it->second->started) {
    result(FlutterError("invalidState", "Job already started"));
    return;
  }
  it->second->started = true;
  result(std::nullopt);
  auto events = it->second->events;
  std::thread([events, dispatcher = dispatcher_, source, destination,
               options]() {
    try {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      auto payload = CompressImageWic(source, destination, options);
      dispatcher->Post([events, payload] {
        events->SendProgress(1.0);
        events->SendCompleted(payload);
      });
    } catch (const FlutterError& error) {
      dispatcher->Post([events, error] {
        events->SendError(error.code(), error.message());
      });
    }
  }).detach();
}

ErrorOr<VideoCapabilitiesMsg>
XueHuaMediaCompressionWindowsPlugin::QueryVideoCapabilities() {
  return QueryVideoCapabilitiesWin();
}

void XueHuaMediaCompressionWindowsPlugin::StartVideoCompress(
    int64_t id, const std::string& input_path, const std::string& output_path,
    const VideoOptionsMsg& options,
    std::function<void(std::optional<FlutterError> reply)> result) {
  auto it = jobs_.find(id);
  if (it == jobs_.end()) {
    result(FlutterError("instanceNotFound", "No job"));
    return;
  }
  if (it->second->started) {
    result(FlutterError("invalidState", "Job already started"));
    return;
  }
  it->second->started = true;
  try {
    it->second->video =
        std::make_unique<VideoJob>(it->second->events.get(), dispatcher_);
    it->second->video->Start(input_path, output_path, options);
    result(std::nullopt);
  } catch (const FlutterError& error) {
    result(error);
  }
}

std::optional<FlutterError> XueHuaMediaCompressionWindowsPlugin::CancelJob(
    int64_t id) {
  auto it = jobs_.find(id);
  if (it == jobs_.end()) {
    return FlutterError("instanceNotFound", "No job");
  }
  if (it->second->video) {
    it->second->video->Cancel();
  }
  return std::nullopt;
}

std::optional<FlutterError> XueHuaMediaCompressionWindowsPlugin::DisposeJob(
    int64_t id) {
  jobs_.erase(id);
  return std::nullopt;
}

}  // namespace xue_hua_media_compression

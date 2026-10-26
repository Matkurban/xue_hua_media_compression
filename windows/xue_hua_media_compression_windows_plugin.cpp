#include "xue_hua_media_compression_windows_plugin.h"

#include <windows.h>

#include <exception>
#include <thread>

#include "image_wic.h"
#include "video_transcoder.h"

namespace xue_hua_media_compression {

void XueHuaMediaCompressionWindowsPlugin::DeleteJobOutput(
    const std::shared_ptr<Job>& job) {
  if (!job->output_opened.exchange(false) || job->output_path.empty()) {
    return;
  }
  const std::wstring wide = Utf8ToWide(job->output_path);
  if (!wide.empty()) {
    DeleteFileW(wide.c_str());
  }
}

void XueHuaMediaCompressionWindowsPlugin::ReleaseOnPlatform(
    const std::shared_ptr<MainThreadDispatcher>& dispatcher,
    const std::shared_ptr<Job>& job) {
  dispatcher->Post([job]() {});
}

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
  for (auto& entry : jobs_) {
    entry.second->cancelled->store(true);
    entry.second->events->Close();
  }
  jobs_.clear();
}

ErrorOr<int64_t> XueHuaMediaCompressionWindowsPlugin::CreateJob() {
  const int64_t id = next_id_++;
  auto job = std::make_shared<Job>();
  job->events =
      std::make_shared<EventStream>(registrar_->messenger(), id);
  jobs_[id] = job;
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
  if (destination.kind() == 1 && destination.path() != nullptr) {
    it->second->output_path = *destination.path();
  }
  auto job = it->second;
  result(std::nullopt);
  std::thread([job, dispatcher = dispatcher_, source, destination, options]() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = co == S_OK || co == S_FALSE;
    auto finish = [&]() {
      if (uninit) {
        CoUninitialize();
      }
      ReleaseOnPlatform(dispatcher, job);
    };
    if (job->cancelled->load()) {
      dispatcher->Post([job]() {
        DeleteJobOutput(job);
        job->events->SendError("cancelled", "Cancelled");
      });
      finish();
      return;
    }
    try {
      auto payload = CompressImageWic(source, destination, options);
      if (!job->output_path.empty()) {
        job->output_opened.store(true);
      }
      dispatcher->Post([job, payload]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          job->events->SendError("cancelled", "Cancelled");
          return;
        }
        job->events->SendProgress(1.0);
        job->events->SendCompleted(payload);
      });
    } catch (const FlutterError& error) {
      dispatcher->Post([job, error]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          job->events->SendError("cancelled", "Cancelled");
          return;
        }
        job->events->SendError(error.code(), error.message());
      });
    } catch (const std::exception& error) {
      const std::string message = error.what();
      dispatcher->Post([job, message]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          job->events->SendError("cancelled", "Cancelled");
          return;
        }
        job->events->SendError("encode", message);
      });
    }
    finish();
  }).detach();
}

ErrorOr<VideoCapabilitiesMsg>
XueHuaMediaCompressionWindowsPlugin::QueryVideoCapabilities() {
  try {
    return QueryVideoCapabilitiesWin();
  } catch (const std::exception& error) {
    return FlutterError("encode", error.what());
  }
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
  it->second->output_path = output_path;
  auto job = it->second;
  result(std::nullopt);
  std::thread([job, dispatcher = dispatcher_, input_path, output_path,
               options]() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = co == S_OK || co == S_FALSE;
    CompressVideoWindows(
        input_path, output_path, options, *job->cancelled, &job->output_opened,
        [job, dispatcher](double value) {
          dispatcher->Post([job, value]() {
            if (!job->cancelled->load()) {
              job->events->SendProgress(value);
            }
          });
        },
        [job, dispatcher](const flutter::EncodableMap& payload) {
          dispatcher->Post([job, payload]() {
            if (job->cancelled->load()) {
              DeleteJobOutput(job);
              job->events->SendError("cancelled", "Cancelled");
              return;
            }
            job->events->SendProgress(1.0);
            job->events->SendCompleted(payload);
          });
        },
        [job, dispatcher](const std::string& code, const std::string& message) {
          dispatcher->Post([job, code, message]() {
            if (job->cancelled->load() || code == "cancelled") {
              DeleteJobOutput(job);
              job->events->SendError("cancelled", "Cancelled");
              return;
            }
            DeleteJobOutput(job);
            job->events->SendError(code, message);
          });
        });
    if (uninit) {
      CoUninitialize();
    }
    ReleaseOnPlatform(dispatcher, job);
  }).detach();
}

std::optional<FlutterError> XueHuaMediaCompressionWindowsPlugin::CancelJob(
    int64_t id) {
  auto it = jobs_.find(id);
  if (it == jobs_.end()) {
    return FlutterError("instanceNotFound", "No job");
  }
  it->second->cancelled->store(true);
  return std::nullopt;
}

std::optional<FlutterError> XueHuaMediaCompressionWindowsPlugin::DisposeJob(
    int64_t id) {
  auto it = jobs_.find(id);
  if (it == jobs_.end()) {
    return std::nullopt;
  }
  it->second->cancelled->store(true);
  it->second->events->Close();
  jobs_.erase(it);
  return std::nullopt;
}

}  // namespace xue_hua_media_compression

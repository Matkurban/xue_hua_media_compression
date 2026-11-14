#include "xue_hua_media_compression_windows_plugin.h"

#include <windows.h>
#include <objbase.h>

#include <algorithm>
#include <exception>
#include <thread>

#include "image_wic.h"
#include "video_transcoder.h"

namespace xue_hua_media_compression {

namespace {

void IgnoreSuccess() {}
void IgnoreError(const FlutterError&) {}

}  // namespace

void XueHuaMediaCompressionWindowsPlugin::SendProgress(
    const std::shared_ptr<Job>& job, double value) {
  if (job->closed || job->terminal || !job->flutter_api) {
    return;
  }
  const double clamped = std::max(0.0, std::min(1.0, value));
  const uint64_t now = GetTickCount64();
  const bool first_positive =
      clamped > 0.0 && clamped < 1.0 && !job->sent_positive;
  if (!first_positive && clamped < 1.0 &&
      (now - job->last_progress_sent_ms) < 100) {
    job->last_progress = clamped;
    return;
  }
  if (first_positive) {
    job->sent_positive = true;
  }
  job->last_progress_sent_ms = now;
  job->last_progress.reset();
  job->flutter_api->OnProgress(clamped, IgnoreSuccess, IgnoreError);
}

void XueHuaMediaCompressionWindowsPlugin::SendImageCompleted(
    const std::shared_ptr<Job>& job, const ImageCompressResultMsg& result) {
  if (job->closed || job->terminal || !job->flutter_api) {
    return;
  }
  job->terminal = true;
  if (job->last_progress.has_value()) {
    const double pending = *job->last_progress;
    job->last_progress.reset();
    job->flutter_api->OnProgress(pending, IgnoreSuccess, IgnoreError);
  }
  job->flutter_api->OnImageCompleted(result, IgnoreSuccess, IgnoreError);
}

void XueHuaMediaCompressionWindowsPlugin::SendVideoCompleted(
    const std::shared_ptr<Job>& job, const VideoCompressResultMsg& result) {
  if (job->closed || job->terminal || !job->flutter_api) {
    return;
  }
  job->terminal = true;
  if (job->last_progress.has_value()) {
    const double pending = *job->last_progress;
    job->last_progress.reset();
    job->flutter_api->OnProgress(pending, IgnoreSuccess, IgnoreError);
  }
  job->flutter_api->OnVideoCompleted(result, IgnoreSuccess, IgnoreError);
}

void XueHuaMediaCompressionWindowsPlugin::SendError(
    const std::shared_ptr<Job>& job, const std::string& code,
    const std::string& message) {
  if (job->closed || job->terminal || !job->flutter_api) {
    return;
  }
  job->terminal = true;
  job->last_progress.reset();
  job->flutter_api->OnError(code, message, IgnoreSuccess, IgnoreError);
}

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
    entry.second->closed = true;
  }
  jobs_.clear();
}

ErrorOr<int64_t> XueHuaMediaCompressionWindowsPlugin::CreateJob() {
  const int64_t id = next_id_++;
  auto job = std::make_shared<Job>();
  job->flutter_api = std::make_unique<MediaCompressionFlutterApi>(
      registrar_->messenger(), "job_" + std::to_string(id));
  jobs_[id] = job;
  return id;
}

void XueHuaMediaCompressionWindowsPlugin::QueryImageCapabilities(
    std::function<void(ErrorOr<ImageCapabilitiesMsg> reply)> result) {
  std::thread([dispatcher = dispatcher_, result = std::move(result)]() mutable {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = co == S_OK || co == S_FALSE;
    try {
      ImageCapabilitiesMsg caps = QueryImageCapabilitiesWic();
      if (uninit) {
        CoUninitialize();
      }
      dispatcher->Post([result = std::move(result),
                        caps = std::move(caps)]() mutable { result(caps); });
    } catch (const FlutterError& error) {
      if (uninit) {
        CoUninitialize();
      }
      dispatcher->Post([result = std::move(result), error]() mutable {
        result(error);
      });
    } catch (const std::exception& error) {
      const std::string message = error.what();
      if (uninit) {
        CoUninitialize();
      }
      dispatcher->Post([result = std::move(result), message]() mutable {
        result(FlutterError("encode", message));
      });
    }
  }).detach();
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
        SendError(job, "cancelled", "Cancelled");
      });
      finish();
      return;
    }
    try {
      dispatcher->Post([job]() {
        if (!job->cancelled->load()) {
          SendProgress(job, 0.25);
        }
      });
      ImageCompressResultMsg payload =
          CompressImageWic(source, destination, options);
      if (!job->output_path.empty()) {
        job->output_opened.store(true);
      }
      dispatcher->Post([job, payload = std::move(payload)]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          SendError(job, "cancelled", "Cancelled");
          return;
        }
        SendProgress(job, 1.0);
        SendImageCompleted(job, payload);
      });
    } catch (const FlutterError& error) {
      dispatcher->Post([job, error]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          SendError(job, "cancelled", "Cancelled");
          return;
        }
        SendError(job, error.code(), error.message());
      });
    } catch (const std::exception& error) {
      const std::string message = error.what();
      dispatcher->Post([job, message]() {
        if (job->cancelled->load()) {
          DeleteJobOutput(job);
          SendError(job, "cancelled", "Cancelled");
          return;
        }
        SendError(job, "encode", message);
      });
    }
    finish();
  }).detach();
}

void XueHuaMediaCompressionWindowsPlugin::QueryVideoCapabilities(
    std::function<void(ErrorOr<VideoCapabilitiesMsg> reply)> result) {
  std::thread([dispatcher = dispatcher_, result = std::move(result)]() mutable {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = co == S_OK || co == S_FALSE;
    try {
      VideoCapabilitiesMsg caps = QueryVideoCapabilitiesWin();
      if (uninit) {
        CoUninitialize();
      }
      dispatcher->Post([result = std::move(result),
                        caps = std::move(caps)]() mutable { result(caps); });
    } catch (const std::exception& error) {
      const std::string message = error.what();
      if (uninit) {
        CoUninitialize();
      }
      dispatcher->Post([result = std::move(result), message]() mutable {
        result(FlutterError("encode", message));
      });
    }
  }).detach();
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
              SendProgress(job, value);
            }
          });
        },
        [job, dispatcher](const VideoCompressResultMsg& payload) {
          dispatcher->Post([job, payload]() {
            if (job->cancelled->load()) {
              DeleteJobOutput(job);
              SendError(job, "cancelled", "Cancelled");
              return;
            }
            SendProgress(job, 1.0);
            SendVideoCompleted(job, payload);
          });
        },
        [job, dispatcher](const std::string& code, const std::string& message) {
          dispatcher->Post([job, code, message]() {
            if (job->cancelled->load() || code == "cancelled") {
              DeleteJobOutput(job);
              SendError(job, "cancelled", "Cancelled");
              return;
            }
            DeleteJobOutput(job);
            SendError(job, code, message);
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
  it->second->closed = true;
  jobs_.erase(it);
  return std::nullopt;
}

}  // namespace xue_hua_media_compression

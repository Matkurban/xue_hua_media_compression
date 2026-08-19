#include "video_transcoder.h"

#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Media.Transcoding.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.FileProperties.h>

#include <algorithm>
#include <filesystem>
#include <stdexcept>
#include <thread>

#include "image_wic.h"

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Media::MediaProperties;
using namespace Windows::Media::Transcoding;
using namespace Windows::Storage;

namespace xue_hua_media_compression {
namespace {

void EnsureApartment() {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
  } catch (const winrt::hresult_error&) {
    // Already initialized on this thread.
  }
}

std::pair<uint32_t, uint32_t> ScaledSize(uint32_t width, uint32_t height,
                                         const int64_t* max_dimension) {
  if (max_dimension == nullptr || *max_dimension <= 0) {
    return {width, height};
  }
  const uint32_t longest = (std::max)(width, height);
  if (longest <= static_cast<uint32_t>(*max_dimension)) {
    return {width, height};
  }
  const double scale = static_cast<double>(*max_dimension) / longest;
  auto even = [](uint32_t v) { return (std::max)(2u, (v / 2) * 2); };
  return {even(static_cast<uint32_t>(width * scale)),
          even(static_cast<uint32_t>(height * scale))};
}

}  // namespace

VideoJob::VideoJob(EventStream* events,
                   std::shared_ptr<MainThreadDispatcher> dispatcher)
    : events_(events), dispatcher_(std::move(dispatcher)) {}

void VideoJob::Start(const std::string& input_path, const std::string& output_path,
                     const VideoOptionsMsg& options) {
  if (input_path.rfind("content://", 0) == 0) {
    throw FlutterError("unsupported", "content:// is Android-only");
  }
  if (!std::filesystem::exists(std::filesystem::u8path(input_path))) {
    throw FlutterError("notFound", "Video not found");
  }
  started_ = true;
  std::thread([this, input_path, output_path, options] {
    EnsureApartment();
    try {
      auto input = StorageFile::GetFileFromPathAsync(
                       winrt::to_hstring(input_path))
                       .get();
      const auto out_path = std::filesystem::u8path(output_path);
      std::filesystem::create_directories(out_path.parent_path());
      auto folder = StorageFolder::GetFolderFromPathAsync(
                        winrt::to_hstring(out_path.parent_path().u8string()))
                        .get();
      auto dest =
          folder
              .CreateFileAsync(winrt::to_hstring(out_path.filename().u8string()),
                               CreationCollisionOption::ReplaceExisting)
              .get();

      MediaEncodingProfile profile;
      ContainerEncodingProperties container;
      container.Subtype(L"MPEG4");
      profile.Container(container);

      VideoEncodingProperties video =
          options.codec() == "h265" ? VideoEncodingProperties::CreateHevc()
                                    : VideoEncodingProperties::CreateH264();
      video.Bitrate(static_cast<uint32_t>(options.bitrate()));
      auto props = input.Properties().GetVideoPropertiesAsync().get();
      uint32_t src_w = props.Width();
      uint32_t src_h = props.Height();
      if (src_w == 0) src_w = 1280;
      if (src_h == 0) src_h = 720;
      auto [out_w, out_h] = ScaledSize(src_w, src_h, options.max_dimension());
      video.Width(out_w);
      video.Height(out_h);
      if (options.fps() != nullptr && *options.fps() > 0) {
        video.FrameRate().Numerator(static_cast<uint32_t>(*options.fps()));
        video.FrameRate().Denominator(1);
      }
      profile.Video(video);
      // Leave audio unset so the MP4 contains no audio track.

      MediaTranscoder transcoder;
      transcoder.HardwareAccelerationEnabled(true);
      auto prepared =
          transcoder.PrepareFileTranscodeAsync(input, dest, profile).get();
      if (!prepared.CanTranscode()) {
        dispatcher_->Post([this] {
          events_->SendError("hardwareUnavailable",
                             "MediaTranscoder cannot transcode this source");
        });
        return;
      }
      auto action = prepared.TranscodeAsync();
      action.Progress([this](auto const&, double progress) {
        if (cancelled_) {
          return;
        }
        const double normalized = progress > 1.0 ? progress / 100.0 : progress;
        dispatcher_->Post([this, normalized] { events_->SendProgress(normalized); });
      });
      action.get();
      if (cancelled_) {
        dispatcher_->Post([this] { events_->SendError("cancelled", "Cancelled"); });
        return;
      }
      const auto size = static_cast<int64_t>(std::filesystem::file_size(out_path));
      dispatcher_->Post([this, output_path, size, options, out_w, out_h] {
        events_->SendCompleted(flutter::EncodableMap{
            {flutter::EncodableValue("outputPath"),
             flutter::EncodableValue(output_path)},
            {flutter::EncodableValue("sizeBytes"), flutter::EncodableValue(size)},
            {flutter::EncodableValue("encoderName"),
             flutter::EncodableValue("MediaTranscoder")},
            {flutter::EncodableValue("codec"),
             flutter::EncodableValue(options.codec())},
            {flutter::EncodableValue("width"),
             flutter::EncodableValue(static_cast<int64_t>(out_w))},
            {flutter::EncodableValue("height"),
             flutter::EncodableValue(static_cast<int64_t>(out_h))},
        });
      });
    } catch (const FlutterError& error) {
      dispatcher_->Post([this, error] {
        events_->SendError(error.code(), error.message());
      });
    } catch (const winrt::hresult_error& error) {
      dispatcher_->Post([this, error] {
        events_->SendError("encode", winrt::to_string(error.message()));
      });
    } catch (const std::exception& error) {
      dispatcher_->Post([this, msg = std::string(error.what())] {
        events_->SendError("encode", msg);
      });
    }
  }).detach();
}

void VideoJob::Cancel() {
  cancelled_ = true;
}

VideoCapabilitiesMsg QueryVideoCapabilitiesWin() {
  flutter::EncodableList codecs = {
      flutter::EncodableValue("h264"),
      flutter::EncodableValue("h265"),
  };
  const std::string name = "MediaTranscoder";
  return VideoCapabilitiesMsg(&name, codecs, false);
}

}  // namespace xue_hua_media_compression

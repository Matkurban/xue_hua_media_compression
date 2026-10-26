#ifndef XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_
#define XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_

#include <atomic>
#include <functional>
#include <string>

#include "messages.g.h"

namespace xue_hua_media_compression {

// Media Foundation encode (Source Reader + Sink Writer). No FFmpeg.
// Callbacks run on the worker thread; the plugin posts them to the platform
// thread. `output_opened` becomes true once the destination file is created.
void CompressVideoWindows(
    const std::string& input_path, const std::string& output_path,
    const VideoOptionsMsg& options, const std::atomic<bool>& cancelled,
    std::atomic<bool>* output_opened,
    const std::function<void(double)>& on_progress,
    const std::function<void(const flutter::EncodableMap&)>& on_completed,
    const std::function<void(const std::string&, const std::string&)>& on_error);

VideoCapabilitiesMsg QueryVideoCapabilitiesWin();

}  // namespace xue_hua_media_compression

#endif  // XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_

#ifndef XUE_HUA_MEDIA_COMPRESSION_LINUX_VIDEO_VAAPI_H_
#define XUE_HUA_MEDIA_COMPRESSION_LINUX_VIDEO_VAAPI_H_

#include <atomic>
#include <functional>
#include <string>

#include "messages.g.h"

XhMcVideoCapabilitiesMsg* query_video_capabilities_vaapi();

// Runs on a worker thread. Reports progress 0-1 and a result map or error.
void compress_video_vaapi(
    const std::string& input_path, const std::string& output_path,
    XhMcVideoOptionsMsg* options, std::atomic<bool>* cancelled,
    const std::function<void(double)>& on_progress,
    const std::function<void(FlValue*)>& on_completed,
    const std::function<void(const char*, const char*)>& on_error);

#endif  // XUE_HUA_MEDIA_COMPRESSION_LINUX_VIDEO_VAAPI_H_

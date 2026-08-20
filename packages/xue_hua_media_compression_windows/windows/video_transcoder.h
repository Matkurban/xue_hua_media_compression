#ifndef XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_
#define XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_

#include <atomic>
#include <memory>
#include <string>

#include "event_stream.h"
#include "main_thread_dispatcher.h"
#include "messages.g.h"

namespace xue_hua_media_compression {

class VideoJob {
 public:
  VideoJob(EventStream* events, std::shared_ptr<MainThreadDispatcher> dispatcher);
  void Start(const std::string& input_path, const std::string& output_path,
             const VideoOptionsMsg& options);
  void Cancel();

 private:
  EventStream* events_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  std::atomic<bool> cancelled_{false};
  std::atomic<bool> started_{false};
};

VideoCapabilitiesMsg QueryVideoCapabilitiesWin();

}  // namespace xue_hua_media_compression

#endif  // XUE_HUA_MEDIA_COMPRESSION_WINDOWS_VIDEO_TRANSCODER_H_

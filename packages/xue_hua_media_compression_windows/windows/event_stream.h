// An EventChannel wrapper that coalesces progress and never drops terminal events.
// EventChannel 封装：进度合并，终态不丢。
#ifndef XUE_HUA_MEDIA_COMPRESSION_WINDOWS_EVENT_STREAM_H_
#define XUE_HUA_MEDIA_COMPRESSION_WINDOWS_EVENT_STREAM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <deque>
#include <memory>
#include <optional>
#include <string>

namespace xue_hua_media_compression {

class EventStream {
 public:
  EventStream(flutter::BinaryMessenger* messenger, int64_t id)
      : channel_(messenger,
                 "xue_hua_media_compression/job_events_" + std::to_string(id),
                 &flutter::StandardMethodCodec::GetInstance()) {
    auto handler = std::make_unique<
        flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [this](const flutter::EncodableValue* arguments,
               std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                   events)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          sink_ = std::move(events);
          if (last_progress_) {
            sink_->Success(MakeProgress(*last_progress_));
            last_progress_.reset();
          }
          while (!pending_terminal_.empty()) {
            sink_->Success(pending_terminal_.front());
            pending_terminal_.pop_front();
          }
          return nullptr;
        },
        [this](const flutter::EncodableValue* arguments)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          sink_.reset();
          return nullptr;
        });
    channel_.SetStreamHandler(std::move(handler));
  }

  void SendProgress(double value) {
    if (value < 0) value = 0;
    if (value > 1) value = 1;
    if (!sink_) {
      last_progress_ = value;
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (value < 1.0 && last_sent_ &&
        now - *last_sent_ < std::chrono::milliseconds(100)) {
      last_progress_ = value;
      return;
    }
    last_sent_ = now;
    last_progress_.reset();
    sink_->Success(MakeProgress(value));
  }

  void SendCompleted(const flutter::EncodableMap& result) {
    flutter::EncodableMap event = {
        {flutter::EncodableValue("type"), flutter::EncodableValue("completed")},
        {flutter::EncodableValue("result"), flutter::EncodableValue(result)},
    };
    SendTerminal(event);
  }

  void SendError(const std::string& code, const std::string& message) {
    flutter::EncodableMap event = {
        {flutter::EncodableValue("type"), flutter::EncodableValue("error")},
        {flutter::EncodableValue("code"), flutter::EncodableValue(code)},
        {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
    };
    SendTerminal(event);
  }

 private:
  static flutter::EncodableValue MakeProgress(double value) {
    return flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("type"), flutter::EncodableValue("progress")},
        {flutter::EncodableValue("value"), flutter::EncodableValue(value)},
    });
  }

  void SendTerminal(const flutter::EncodableMap& event) {
    if (sink_) {
      sink_->Success(flutter::EncodableValue(event));
    } else {
      pending_terminal_.push_back(flutter::EncodableValue(event));
    }
  }

  flutter::EventChannel<flutter::EncodableValue> channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::optional<double> last_progress_;
  std::deque<flutter::EncodableValue> pending_terminal_;
  std::optional<std::chrono::steady_clock::time_point> last_sent_;
};

}  // namespace xue_hua_media_compression

#endif  // XUE_HUA_MEDIA_COMPRESSION_WINDOWS_EVENT_STREAM_H_

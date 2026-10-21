#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif
import Foundation
import QuartzCore

/// Per-job EventChannel: coalesce progress until listen; never drop terminal events.
///
/// 每个会话一条 EventChannel：listen 前进度合并为最新一条；终态必须入队。
final class JobEventStream: NSObject, FlutterStreamHandler {
  private let channel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var lastProgress: Double?
  private var pendingTerminal: [[String: Any?]] = []
  private var lastProgressSentAt: CFTimeInterval = 0

  init(messenger: FlutterBinaryMessenger, id: Int64) {
    channel = FlutterEventChannel(
      name: "xue_hua_media_compression/job_events_\(id)",
      binaryMessenger: messenger)
    super.init()
    channel.setStreamHandler(self)
  }

  func sendProgress(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    runOnMain {
      let now = CACurrentMediaTime()
      if self.sink == nil {
        self.lastProgress = clamped
        return
      }
      if clamped < 1 && now - self.lastProgressSentAt < 0.1 {
        self.lastProgress = clamped
        return
      }
      self.lastProgressSentAt = now
      self.lastProgress = nil
      self.sink?(["type": "progress", "value": clamped])
    }
  }

  func sendCompleted(_ result: [String: Any?]) {
    runOnMain {
      let event: [String: Any?] = ["type": "completed", "result": result]
      if let sink = self.sink {
        sink(event)
      } else {
        self.pendingTerminal.append(event)
      }
    }
  }

  func sendError(code: String, message: String, details: String? = nil) {
    runOnMain {
      let event: [String: Any?] = [
        "type": "error",
        "code": code,
        "message": message,
        "details": details,
      ]
      if let sink = self.sink {
        sink(event)
      } else {
        self.pendingTerminal.append(event)
      }
    }
  }

  func dispose() {
    runOnMain {
      self.sink = nil
      self.channel.setStreamHandler(nil)
      self.pendingTerminal.removeAll()
      self.lastProgress = nil
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    if let lastProgress {
      events(["type": "progress", "value": lastProgress])
      self.lastProgress = nil
    }
    for event in pendingTerminal {
      events(event)
    }
    pendingTerminal.removeAll()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}

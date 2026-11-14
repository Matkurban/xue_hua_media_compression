import Foundation

/// Relays job progress and terminal results through Pigeon's `@FlutterApi` in
/// strict FIFO order while throttling intermediate progress updates to 100 ms.
final class JobFlutterEventRelay: @unchecked Sendable {
  private enum PendingEvent {
    case progress(Double)
    case imageCompleted(ImageCompressResultMsg)
    case videoCompleted(VideoCompressResultMsg)
    case error(String, String)
  }

  private let lock = NSLock()
  private let flutterApi: MediaCompressionFlutterApi?
  private var terminal = false
  private var sentPositive = false
  private var lastProgressSentAt: TimeInterval = 0
  private var lastProgress: Double?
  private var queue: [PendingEvent] = []
  private var draining = false

  init(flutterApi: MediaCompressionFlutterApi?) {
    self.flutterApi = flutterApi
  }

  func sendProgress(_ value: Double) {
    let clamped = max(0.0, min(1.0, value))
    lock.lock()
    defer { lock.unlock() }
    guard !terminal else {
      return
    }
    lastProgress = clamped
    let now = ProcessInfo.processInfo.systemUptime
    let firstPositive = clamped > 0.0 && clamped < 1.0 && !sentPositive
    if !firstPositive && clamped < 1.0 && (now - lastProgressSentAt) < 0.1 {
      return
    }
    if firstPositive {
      sentPositive = true
    }
    lastProgressSentAt = now
    if case .progress? = queue.last {
      queue[queue.count - 1] = .progress(clamped)
    } else {
      queue.append(.progress(clamped))
    }
    scheduleDrainLocked()
  }

  func sendImageCompleted(_ result: ImageCompressResultMsg) {
    lock.lock()
    defer { lock.unlock() }
    guard !terminal else {
      return
    }
    terminal = true
    if let last = lastProgress, last < 1.0 {
      queue.append(.progress(1.0))
    }
    queue.append(.imageCompleted(result))
    scheduleDrainLocked()
  }

  func sendVideoCompleted(_ result: VideoCompressResultMsg) {
    lock.lock()
    defer { lock.unlock() }
    guard !terminal else {
      return
    }
    terminal = true
    if let last = lastProgress, last < 1.0 {
      queue.append(.progress(1.0))
    }
    queue.append(.videoCompleted(result))
    scheduleDrainLocked()
  }

  func sendError(code: String, message: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !terminal else {
      return
    }
    terminal = true
    queue.append(.error(code, message))
    scheduleDrainLocked()
  }

  func dispose() {
    lock.lock()
    terminal = true
    queue.removeAll(keepingCapacity: false)
    lock.unlock()
  }

  private func scheduleDrainLocked() {
    guard !draining, !queue.isEmpty else {
      return
    }
    guard let api = flutterApi else {
      queue.removeAll(keepingCapacity: false)
      return
    }
    draining = true
    Task {
      await self.drainLoop(api: api)
    }
  }

  private func drainLoop(api: MediaCompressionFlutterApi) async {
    while true {
      let next: PendingEvent? = {
        lock.lock()
        defer { lock.unlock() }
        if queue.isEmpty {
          draining = false
          return nil
        }
        return queue.removeFirst()
      }()

      guard let event = next else {
        return
      }

      do {
        switch event {
        case .progress(let value):
          try await api.onProgress(value: value)
        case .imageCompleted(let result):
          try await api.onImageCompleted(result: result)
        case .videoCompleted(let result):
          try await api.onVideoCompleted(result: result)
        case .error(let code, let message):
          try await api.onError(code: code, message: message)
        }
      } catch {
        // Ignore delivery failures after Dart unregisters the job callback.
      }
    }
  }
}

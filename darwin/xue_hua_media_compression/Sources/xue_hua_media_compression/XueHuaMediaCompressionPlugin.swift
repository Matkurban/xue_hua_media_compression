#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif
import Foundation

/// iOS / macOS entry point. Registers the Pigeon HostApi.
///
/// iOS / macOS 入口：注册 Pigeon HostApi。
public class XueHuaMediaCompressionPlugin: NSObject, FlutterPlugin, MediaCompressionHostApi {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let plugin = XueHuaMediaCompressionPlugin(messenger: messenger)
    MediaCompressionHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
    let retain =
      FlutterMethodChannel(
        name: "xue_hua_media_compression/retain", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(plugin, channel: retain)
  }

  private let messenger: FlutterBinaryMessenger
  private var jobs: [Int64: Job] = [:]
  private var nextId: Int64 = 1

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }

  func createJob() throws -> Int64 {
    let id = nextId
    nextId += 1
    let job = Job(id: id, events: JobEventStream(messenger: messenger, id: id))
    job.onStateChange = { [weak self] in
      self?.releaseIfIdle(id)
    }
    jobs[id] = job
    return id
  }

  func queryImageCapabilities() throws -> ImageCapabilitiesMsg {
    ImageCompressor.queryCapabilities()
  }

  func startImageCompress(
    id: Int64,
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg
  ) async throws {
    guard let job = jobs[id] else {
      throw PigeonError(code: "instanceNotFound", message: "No job \(id)", details: nil)
    }
    if job.started {
      throw PigeonError(code: "invalidState", message: "Job \(id) already started", details: nil)
    }
    job.started = true
    let outputPath = destination.kind == 1 ? destination.path : nil
    DispatchQueue.global(qos: .userInitiated).async {
      func finishCancelled() {
        if let outputPath {
          ImageCompressor.removeFile(at: outputPath)
        }
        job.events.sendError(code: "cancelled", message: "Cancelled")
        job.markFinished()
      }
      do {
        if job.cancelled {
          finishCancelled()
          return
        }
        job.events.sendProgress(0.05)
        let result = try ImageCompressor.compress(
          source: source, destination: destination, options: options)
        if job.cancelled {
          finishCancelled()
          return
        }
        job.events.sendProgress(1)
        job.events.sendCompleted(result)
        job.markFinished()
      } catch let pigeon as PigeonError {
        if job.cancelled {
          finishCancelled()
          return
        }
        job.events.sendError(
          code: pigeon.code, message: pigeon.message ?? pigeon.code,
          details: pigeon.details.map { "\($0)" })
        job.markFinished()
      } catch {
        if job.cancelled {
          finishCancelled()
          return
        }
        job.events.sendError(code: "encode", message: error.localizedDescription, details: "\(error)")
        job.markFinished()
      }
    }
  }

  func queryVideoCapabilities() throws -> VideoCapabilitiesMsg {
    VideoCompressor.queryCapabilities()
  }

  func startVideoCompress(
    id: Int64,
    inputPath: String,
    outputPath: String,
    options: VideoOptionsMsg
  ) async throws {
    guard let job = jobs[id] else {
      throw PigeonError(code: "instanceNotFound", message: "No job \(id)", details: nil)
    }
    if job.started {
      throw PigeonError(code: "invalidState", message: "Job \(id) already started", details: nil)
    }
    job.started = true
    do {
      let video = try VideoCompressor(
        events: job.events,
        inputPath: inputPath,
        outputPath: outputPath,
        options: options,
        isCancelled: { [weak job] in
          job?.cancelled ?? true
        },
        onFinished: { [weak job] in
          job?.markFinished()
        })
      job.video = video
      if job.cancelled {
        video.cancel()
      }
    } catch {
      job.markFinished()
      throw error
    }
  }

  func cancelJob(id: Int64) throws {
    guard let job = jobs[id] else {
      throw PigeonError(code: "instanceNotFound", message: "No job \(id)", details: nil)
    }
    job.cancelled = true
    job.video?.cancel()
  }

  func disposeJob(id: Int64) throws {
    guard let job = jobs[id] else { return }
    job.disposeRequested = true
    job.cancelled = true
    job.video?.cancel()
    releaseIfIdle(id)
  }

  /// 工作线程还在跑时保留 EventChannel，避免 dispose 把通道从编码器底下拆掉。
  ///
  /// Keeps the event channel until the worker finishes so dispose cannot
  /// tear it down underneath the encoder.
  private func releaseIfIdle(_ id: Int64) {
    guard let job = jobs[id] else { return }
    guard job.disposeRequested, job.finished || !job.started else { return }
    job.video = nil
    job.events.dispose()
    jobs.removeValue(forKey: id)
  }
}

private final class Job: @unchecked Sendable {
  let id: Int64
  let events: JobEventStream
  var started = false
  var finished = false
  var disposeRequested = false
  var video: VideoCompressor?
  var onStateChange: (() -> Void)?
  private let lock = NSLock()
  private var _cancelled = false

  var cancelled: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _cancelled
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _cancelled = newValue
    }
  }

  init(id: Int64, events: JobEventStream) {
    self.id = id
    self.events = events
  }

  func markFinished() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.finished = true
      self.onStateChange?()
    }
  }
}

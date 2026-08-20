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
    jobs[id] = Job(id: id, events: JobEventStream(messenger: messenger, id: id))
    return id
  }

  func queryImageCapabilities() throws -> ImageCapabilitiesMsg {
    ImageCompressor.queryCapabilities()
  }

  func startImageCompress(
    id: Int64,
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let job = jobs[id] else {
      completion(
        .failure(PigeonError(code: "instanceNotFound", message: "No job \(id)", details: nil)))
      return
    }
    if job.started {
      completion(
        .failure(PigeonError(code: "invalidState", message: "Job \(id) already started", details: nil)))
      return
    }
    job.started = true
    completion(.success(()))
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        if job.cancelled {
          job.events.sendError(code: "cancelled", message: "Cancelled")
          return
        }
        job.events.sendProgress(0.05)
        let result = try ImageCompressor.compress(
          source: source, destination: destination, options: options)
        if job.cancelled {
          job.events.sendError(code: "cancelled", message: "Cancelled")
          return
        }
        job.events.sendProgress(1)
        job.events.sendCompleted(result)
      } catch let pigeon as PigeonError {
        job.events.sendError(
          code: pigeon.code, message: pigeon.message ?? pigeon.code,
          details: pigeon.details.map { "\($0)" })
      } catch {
        job.events.sendError(code: "encode", message: error.localizedDescription, details: "\(error)")
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
    options: VideoOptionsMsg,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let job = jobs[id] else {
      completion(
        .failure(PigeonError(code: "instanceNotFound", message: "No job \(id)", details: nil)))
      return
    }
    if job.started {
      completion(
        .failure(PigeonError(code: "invalidState", message: "Job \(id) already started", details: nil)))
      return
    }
    job.started = true
    do {
      job.video = try VideoCompressor(
        events: job.events, inputPath: inputPath, outputPath: outputPath, options: options)
      completion(.success(()))
    } catch {
      completion(.failure(error))
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
    if let job = jobs.removeValue(forKey: id) {
      job.cancelled = true
      job.video?.cancel()
      job.events.dispose()
    }
  }
}

private final class Job {
  let id: Int64
  let events: JobEventStream
  var started = false
  var cancelled = false
  var video: VideoCompressor?

  init(id: Int64, events: JobEventStream) {
    self.id = id
    self.events = events
  }
}

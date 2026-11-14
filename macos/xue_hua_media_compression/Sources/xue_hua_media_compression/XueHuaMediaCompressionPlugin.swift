import FlutterMacOS
import Foundation

public final class XueHuaMediaCompressionPlugin:
  NSObject,
  FlutterPlugin,
  MediaCompressionHostApi,
  @unchecked Sendable
{
  private final class Job: @unchecked Sendable {
    let id: Int64
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var finished = false
    private var relay: JobFlutterEventRelay?
    private var video: VideoCompressor?

    init(id: Int64) {
      self.id = id
    }

    func begin(relay: JobFlutterEventRelay) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !started, !finished else {
        return false
      }
      started = true
      self.relay = relay
      return true
    }

    func attach(video: VideoCompressor) {
      lock.lock()
      let alreadyCancelled = cancelled
      self.video = video
      lock.unlock()
      if alreadyCancelled {
        video.cancel()
      }
    }

    func isCancelled() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      cancelled = true
      let activeVideo = video
      lock.unlock()
      activeVideo?.cancel()
    }

    func markFinished() {
      lock.lock()
      finished = true
      video = nil
      lock.unlock()
    }

    func dispose() {
      cancel()
      lock.lock()
      let activeRelay = relay
      relay = nil
      finished = true
      lock.unlock()
      activeRelay?.dispose()
    }
  }

  private weak var registrar: (any FlutterPluginRegistrar)?
  private let lock = NSLock()
  private var nextId: Int64 = 1
  private var jobs: [Int64: Job] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = XueHuaMediaCompressionPlugin(registrar: registrar)
    registrar.publish(instance)
    MediaCompressionHostApiSetup.register(api: instance, registrar: registrar)
  }

  deinit {
    lock.lock()
    let activeJobs = Array(jobs.values)
    jobs.removeAll()
    lock.unlock()
    for job in activeJobs {
      job.dispose()
    }
  }

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func createJob() throws -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    let id = nextId
    nextId += 1
    jobs[id] = Job(id: id)
    return id
  }

  func queryImageCapabilities() async throws -> ImageCapabilitiesMsg {
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: ImageCompressor.queryCapabilities())
      }
    }
  }

  func startImageCompress(
    id: Int64,
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg
  ) async throws {
    let job = try lookupJob(id: id)
    let relay = try makeRelay(for: id)
    guard job.begin(relay: relay) else {
      throw PigeonError(
        code: "invalidState",
        message: "Job \(id) has already started",
        details: nil
      )
    }

    DispatchQueue.global(qos: .userInitiated).async {
      relay.sendProgress(0.0)
      do {
        let result = try ImageCompressor.compress(
          source: source,
          destination: destination,
          options: options,
          reportProgress: { value in relay.sendProgress(value) },
          isCancelled: { job.isCancelled() }
        )
        if job.isCancelled() {
          if let outPath = result.outputPath {
            ImageCompressor.removeFile(at: URL(fileURLWithPath: outPath))
          }
          relay.sendError(code: "cancelled", message: "Job cancelled")
        } else {
          relay.sendProgress(1.0)
          relay.sendImageCompleted(result)
        }
      } catch let err as PigeonError {
        relay.sendError(
          code: err.code ?? "encode",
          message: err.message ?? "Image compression failed"
        )
      } catch {
        relay.sendError(code: "encode", message: error.localizedDescription)
      }
      job.markFinished()
    }
  }

  func queryVideoCapabilities() async throws -> VideoCapabilitiesMsg {
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: VideoCompressor.queryCapabilities())
      }
    }
  }

  func startVideoCompress(
    id: Int64,
    inputPath: String,
    outputPath: String,
    options: VideoOptionsMsg
  ) async throws {
    let job = try lookupJob(id: id)
    let relay = try makeRelay(for: id)
    guard job.begin(relay: relay) else {
      throw PigeonError(
        code: "invalidState",
        message: "Job \(id) has already started",
        details: nil
      )
    }

    let compressor = VideoCompressor(
      inputPath: inputPath,
      outputPath: outputPath,
      options: options,
      relay: relay,
      onFinished: { job.markFinished() }
    )
    job.attach(video: compressor)
    DispatchQueue.global(qos: .userInitiated).async {
      compressor.start()
    }
  }

  func cancelJob(id: Int64) throws {
    lock.lock()
    let job = jobs[id]
    lock.unlock()
    job?.cancel()
  }

  func disposeJob(id: Int64) throws {
    lock.lock()
    let job = jobs.removeValue(forKey: id)
    lock.unlock()
    job?.dispose()
  }

  private func lookupJob(id: Int64) throws -> Job {
    lock.lock()
    defer { lock.unlock() }
    guard let job = jobs[id] else {
      throw PigeonError(
        code: "instanceNotFound",
        message: "Job \(id) was not found",
        details: nil
      )
    }
    return job
  }

  private func makeRelay(for id: Int64) throws -> JobFlutterEventRelay {
    lock.lock()
    let currentRegistrar = registrar
    lock.unlock()
    let flutterApi = currentRegistrar.flatMap {
      MediaCompressionFlutterApiRegistrar.getInstance(registrar: $0, name: "job_\(id)")
    }
    return JobFlutterEventRelay(flutterApi: flutterApi)
  }
}

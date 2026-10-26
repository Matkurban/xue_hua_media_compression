import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox NV12 pipeline via AVAssetReader / AVAssetWriter.
/// Audio is kept (AAC passthrough or transcode) unless `keepAudio` is false.
/// Hardware is used when the device has it and the frame size can use it;
/// otherwise the platform software encoder runs. No FFmpeg.
///
/// VideoToolbox NV12 管线（AVAssetReader / AVAssetWriter）。
/// 默认保留音轨（AAC 透传或转码），`keepAudio` 为 false 时丢弃。
/// 设备有硬编且尺寸可用时走硬编，否则走系统软编。不使用 FFmpeg。
final class VideoCompressor {
  private static let nv12Formats: [OSType] = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_32BGRA,
  ]

  private let events: JobEventStream
  private let options: VideoOptionsMsg
  private let outputURL: URL
  private let isCancelled: () -> Bool
  private let onFinished: () -> Void
  private let encodeQueue = DispatchQueue(
    label: "com.xuehua.media_compression.video", qos: .userInitiated)
  /// Writer teardown never runs on `encodeQueue` or the platform thread.
  /// `cancelWriting` waits for the media callback; doing that from the callback
  /// or from the main thread deadlocks the session.
  ///
  /// 拆编码器不在 `encodeQueue` 上，也不在平台线程上。
  /// `cancelWriting` 会等媒体回调；在回调里或主线程里调用会把会话卡死。
  private let controlQueue = DispatchQueue(
    label: "com.xuehua.media_compression.video.control", qos: .userInitiated)
  private let encodeQueueToken = DispatchSpecificKey<UInt8>()
  private let stateLock = NSLock()
  private var _cancelled = false
  private var didFinish = false
  private var failed = false
  private var cancelled: Bool {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _cancelled
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _cancelled = newValue
    }
  }
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?
  private var resultEncoderName: String

  init(
    events: JobEventStream,
    inputPath: String,
    outputPath: String,
    options: VideoOptionsMsg,
    isCancelled: @escaping () -> Bool,
    onFinished: @escaping () -> Void
  ) throws {
    let resolvedInput = Self.filesystemPath(inputPath)
    if resolvedInput.hasPrefix("content://") {
      throw PigeonError(
        code: "unsupported", message: "content:// is Android-only", details: nil)
    }
    var isDirectory = ObjCBool(false)
    if !FileManager.default.fileExists(atPath: resolvedInput, isDirectory: &isDirectory) {
      throw PigeonError(
        code: "notFound", message: "Video not found: \(resolvedInput)", details: nil)
    }
    if isDirectory.boolValue {
      throw PigeonError(
        code: "io", message: "Video path is a directory: \(resolvedInput)", details: nil)
    }
    self.events = events
    self.options = options
    self.isCancelled = isCancelled
    self.onFinished = onFinished
    self.resultEncoderName = "VideoToolbox:H264"
    let resolvedOutput = Self.filesystemPath(outputPath)
    self.outputURL = URL(fileURLWithPath: resolvedOutput)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    encodeQueue.setSpecific(key: encodeQueueToken, value: 1)
    let asset = AVURLAsset(url: URL(fileURLWithPath: resolvedInput))
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
      // Leave the load callback before touching the reader/writer so cancel()
      // can observe the job flag that was set while init was still returning.
      DispatchQueue.global(qos: .userInitiated).async {
        self?.handleLoaded(asset)
      }
    }
  }

  func cancel() {
    cancelled = true
    // Return immediately. The platform channel runs on the main thread, and
    // waiting here for AVAssetWriter blocks that thread forever.
    requestStop(code: "cancelled", message: "Cancelled", details: nil)
  }

  static func queryCapabilities() -> VideoCapabilitiesMsg {
    let h264 = availability(kCMVideoCodecType_H264)
    let hevc = availability(kCMVideoCodecType_HEVC)
    var codecs: [String] = []
    if h264.any { codecs.append("h264") }
    if hevc.any { codecs.append("h265") }
    let hardware = h264.hardware || hevc.hardware
    return VideoCapabilitiesMsg(
      encoderName: hardware ? "VideoToolboxHW" : nil,
      codecs: codecs,
      acceptsContentUri: false)
  }

  private func handleLoaded(_ asset: AVAsset) {
    if isStopped() {
      requestStop(code: "cancelled", message: "Cancelled", details: nil)
      return
    }
    var error: NSError?
    guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded else {
      requestStop(
        code: "decode",
        message: error?.localizedDescription ?? "Unable to load tracks",
        details: error?.description)
      return
    }
    do {
      try configure(asset: asset)
    } catch let pigeon as PigeonError {
      requestStop(
        code: pigeon.code, message: pigeon.message ?? pigeon.code,
        details: pigeon.details.map { "\($0)" })
    } catch {
      requestStop(code: "encode", message: error.localizedDescription, details: "\(error)")
    }
  }

  private func configure(asset: AVAsset) throws {
    try ensureRunning()
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw PigeonError(code: "decode", message: "No video track", details: nil)
    }
    let compose = needsComposition(for: videoTrack)
    let outSize = outputSize(for: videoTrack, compose: compose)
    let resolved = try resolveCodec(width: outSize.width, height: outSize.height)
    let reader = try AVAssetReader(asset: asset)
    let readerOutput = try attachReaderOutput(
      reader: reader, track: videoTrack, asset: asset, compose: compose, renderSize: outSize)
    var audioReader: AVAssetReaderOutput?
    if options.keepAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
      let output = try makeAudioReaderOutput(track: audioTrack)
      guard reader.canAdd(output) else {
        throw PigeonError(code: "decode", message: "Cannot attach audio reader", details: nil)
      }
      reader.add(output)
      audioReader = output
    }
    let opened = try openWriter(
      wantHardware: resolved.hardware,
      codec: resolved.codec,
      width: outSize.width,
      height: outSize.height,
      transform: compose ? .identity : videoTrack.preferredTransform,
      audioTrack: options.keepAudio ? asset.tracks(withMediaType: .audio).first : nil)
    if opened.usedHardware != resolved.hardware {
      let label = resolved.codec == .hevc ? "H265" : "H264"
      resultEncoderName = "VideoToolbox:\(label)"
    }
    try ensureRunning()
    guard reader.startReading() else {
      throw PigeonError(
        code: "decode",
        message: reader.error?.localizedDescription ?? "AVAssetReader failed",
        details: nil)
    }
    opened.writer.startSession(atSourceTime: .zero)
    stateLock.lock()
    self.reader = reader
    self.writer = opened.writer
    stateLock.unlock()
    if isStopped() {
      requestStop(code: "cancelled", message: "Cancelled", details: nil)
      return
    }
    let seconds = CMTimeGetSeconds(asset.duration)
    let duration = seconds.isFinite && seconds > 0 ? seconds : 0
    pump(
      reader: reader,
      writer: opened.writer,
      videoOutput: readerOutput,
      videoInput: opened.videoInput,
      audioOutput: audioReader,
      audioInput: opened.audioInput,
      duration: duration,
      width: outSize.width,
      height: outSize.height)
  }

  /// 仅在需要缩放、降帧、把奇数边补成偶数，或把旋转烘焙进像素时才重绘。
  ///
  /// Re-render only for a downscale, a frame-rate drop, even dimensions,
  /// or baking a rotation into the pixels.
  private func needsComposition(for track: AVAssetTrack) -> Bool {
    let display = Self.displaySize(of: track)
    let natural = track.naturalSize
    if abs(display.width - abs(natural.width)) > 1 || abs(display.height - abs(natural.height)) > 1
    {
      return true
    }
    let width = Int(display.width.rounded())
    let height = Int(display.height.rounded())
    if width < 2 || height < 2 || width % 2 != 0 || height % 2 != 0 {
      return true
    }
    if let maxDimension = options.maxDimension, maxDimension > 0 {
      if max(display.width, display.height) > CGFloat(maxDimension) {
        return true
      }
    }
    if let fps = options.fps, fps > 0 {
      let sourceRate = track.nominalFrameRate
      if sourceRate <= 0 || Float(fps) < sourceRate - 0.5 {
        return true
      }
    }
    return false
  }

  private func resolveCodec(width: Int, height: Int) throws -> (codec: AVVideoCodecType, hardware: Bool)
  {
    let codecType: CMVideoCodecType
    let codec: AVVideoCodecType
    let label: String
    switch options.codec {
    case "h265":
      codecType = kCMVideoCodecType_HEVC
      codec = .hevc
      label = "H265"
    case "h264":
      codecType = kCMVideoCodecType_H264
      codec = .h264
      label = "H264"
    default:
      throw PigeonError(
        code: "unsupported", message: "Unknown video codec \(options.codec)", details: nil)
    }
    let support = Self.availability(codecType, width: width, height: height)
    guard support.any else {
      throw PigeonError(
        code: "hardwareUnavailable",
        message: "No \(label) encoder is available",
        details: nil)
    }
    let hardware = support.hardware && width >= 64 && height >= 64
    resultEncoderName = "\(hardware ? "VideoToolboxHW" : "VideoToolbox"):\(label)"
    return (codec, hardware)
  }

  private func outputSize(for track: AVAssetTrack, compose: Bool) -> (width: Int, height: Int) {
    if !compose {
      return (
        width: Self.even(Int(track.naturalSize.width.rounded())),
        height: Self.even(Int(track.naturalSize.height.rounded()))
      )
    }
    var display = Self.displaySize(of: track)
    if let maxDimension = options.maxDimension, maxDimension > 0 {
      let longest = max(display.width, display.height)
      if longest > CGFloat(maxDimension) {
        let scale = CGFloat(maxDimension) / longest
        display.width *= scale
        display.height *= scale
      }
    }
    return (
      width: Self.even(Int(display.width)),
      height: Self.even(Int(display.height))
    )
  }

  private struct OpenedWriter {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let usedHardware: Bool
  }

  private func openWriter(
    wantHardware: Bool,
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    transform: CGAffineTransform,
    audioTrack: AVAssetTrack?
  ) throws -> OpenedWriter {
    if wantHardware {
      do {
        return try attemptWriter(
          hardware: true,
          codec: codec,
          width: width,
          height: height,
          transform: transform,
          audioTrack: audioTrack)
      } catch let error as PigeonError where error.code == "encode" {
        // The hardware encoder rejected this size or profile. Software still
        // satisfies the contract, and the result name records that fallback.
      }
    }
    return try attemptWriter(
      hardware: false,
      codec: codec,
      width: width,
      height: height,
      transform: transform,
      audioTrack: audioTrack)
  }

  private func attemptWriter(
    hardware: Bool,
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    transform: CGAffineTransform,
    audioTrack: AVAssetTrack?
  ) throws -> OpenedWriter {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    } catch {
      throw PigeonError(code: "io", message: error.localizedDescription, details: "\(error)")
    }
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: writerSettings(
        codec: codec, width: width, height: height, hardware: hardware))
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = transform
    guard writer.canAdd(videoInput) else {
      discard(writer)
      throw PigeonError(code: "encode", message: "Cannot attach writer input", details: nil)
    }
    writer.add(videoInput)
    var audioInput: AVAssetWriterInput?
    if let audioTrack {
      audioInput = try makeAudioWriterInput(track: audioTrack)
      guard let audioInput, writer.canAdd(audioInput) else {
        discard(writer)
        throw PigeonError(
          code: "unsupported",
          message: "AAC audio encoder is not available",
          details: nil)
      }
      writer.add(audioInput)
    }
    guard writer.startWriting() else {
      let message = writer.error?.localizedDescription ?? "AVAssetWriter failed"
      let details = writer.error.map { "\($0)" }
      discard(writer)
      throw PigeonError(code: "encode", message: message, details: details)
    }
    return OpenedWriter(
      writer: writer, videoInput: videoInput, audioInput: audioInput, usedHardware: hardware)
  }

  private func discard(_ writer: AVAssetWriter) {
    if writer.status == .writing {
      writer.cancelWriting()
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }
  }

  private func attachReaderOutput(
    reader: AVAssetReader,
    track: AVAssetTrack,
    asset: AVAsset,
    compose: Bool,
    renderSize: (width: Int, height: Int)
  ) throws -> AVAssetReaderOutput {
    if compose {
      let composition = Self.makeVideoComposition(
        asset: asset,
        track: track,
        renderSize: CGSize(width: renderSize.width, height: renderSize.height),
        frameDuration: frameDuration(for: track))
      for format in Self.nv12Formats {
        let output = AVAssetReaderVideoCompositionOutput(
          videoTracks: [track],
          videoSettings: Self.pixelSettings(format))
        output.alwaysCopiesSampleData = false
        output.videoComposition = composition
        if reader.canAdd(output) {
          reader.add(output)
          return output
        }
      }
      throw PigeonError(code: "decode", message: "Cannot attach composition output", details: nil)
    }
    for format in Self.nv12Formats {
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pixelSettings(format))
      output.alwaysCopiesSampleData = false
      if reader.canAdd(output) {
        reader.add(output)
        return output
      }
    }
    throw PigeonError(code: "decode", message: "Cannot attach reader output", details: nil)
  }

  /// 源音轨已是 AAC 时直接透传，否则解码为 PCM 再编码为 AAC。
  ///
  /// Passes AAC audio through untouched; otherwise decodes to PCM and
  /// re-encodes to AAC.
  private func makeAudioReaderOutput(track: AVAssetTrack) throws -> AVAssetReaderTrackOutput {
    let formats = (track.formatDescriptions as? [CMFormatDescription]) ?? []
    let isAAC = formats.contains {
      CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
    }
    let output: AVAssetReaderTrackOutput
    if isAAC {
      output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    } else {
      output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings())
    }
    output.alwaysCopiesSampleData = false
    return output
  }

  private func makeAudioWriterInput(track: AVAssetTrack) throws -> AVAssetWriterInput {
    let formats = (track.formatDescriptions as? [CMFormatDescription]) ?? []
    let isAAC = formats.contains {
      CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
    }
    if isAAC {
      return AVAssetWriterInput(
        mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
    }
    var channels = 2
    var sampleRate = 44_100.0
    if let format = formats.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    {
      if asbd.mChannelsPerFrame > 0 {
        channels = min(2, Int(asbd.mChannelsPerFrame))
      }
      if asbd.mSampleRate > 0 {
        sampleRate = min(48_000, max(8_000, asbd.mSampleRate))
      }
    }
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: channels,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: 128_000,
      ])
    input.expectsMediaDataInRealTime = false
    return input
  }

  private func frameDuration(for track: AVAssetTrack) -> CMTime {
    if let fps = options.fps, fps > 0 {
      return CMTime(value: 1, timescale: CMTimeScale(fps))
    }
    let rate = track.nominalFrameRate
    let timescale = CMTimeScale(max(1, Int((rate > 0 ? rate : 30).rounded())))
    return CMTime(value: 1, timescale: timescale)
  }

  private func writerSettings(
    codec: AVVideoCodecType, width: Int, height: Int, hardware: Bool
  ) -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: options.bitrate,
      kVTCompressionPropertyKey_RealTime as String: false,
      kVTCompressionPropertyKey_AllowFrameReordering as String: false,
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    if let fps = options.fps, fps > 0 {
      compression[AVVideoExpectedSourceFrameRateKey] = fps
    }
    if let gop = options.keyframeInterval, gop > 0 {
      compression[AVVideoMaxKeyFrameIntervalKey] = gop
      compression[kVTCompressionPropertyKey_MaxKeyFrameInterval as String] = gop
      compression[kVTCompressionPropertyKey_AllowTemporalCompression as String] = true
      if let fps = options.fps, fps > 0 {
        let seconds = Double(gop) / Double(fps)
        compression[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String] = seconds
      }
    }
    var settings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]
    if hardware {
      #if os(macOS)
        settings[AVVideoEncoderSpecificationKey] = [
          kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
      #else
        if #available(iOS 17.4, *) {
          settings[AVVideoEncoderSpecificationKey] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
          ]
        }
      #endif
    }
    return settings
  }

  private func pump(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    videoOutput: AVAssetReaderOutput,
    videoInput: AVAssetWriterInput,
    audioOutput: AVAssetReaderOutput?,
    audioInput: AVAssetWriterInput?,
    duration: Double,
    width: Int,
    height: Int
  ) {
    var remainingTracks = 1 + (audioInput != nil ? 1 : 0)

    func fail(code: String, message: String, details: String?) {
      // Do not touch AVAssetWriter here. This runs on encodeQueue.
      self.requestStop(code: code, message: message, details: details)
    }

    func finishTrack(_ input: AVAssetWriterInput) {
      stateLock.lock()
      let stop = failed || didFinish
      stateLock.unlock()
      if stop { return }
      input.markAsFinished()
      remainingTracks -= 1
      if remainingTracks == 0 {
        writer.finishWriting { [weak self] in
          self?.finish(writer: writer, width: width, height: height)
        }
      }
    }

    func pumpTrack(
      output: AVAssetReaderOutput,
      input: AVAssetWriterInput,
      reportsProgress: Bool
    ) {
      input.requestMediaDataWhenReady(on: encodeQueue) { [weak self] in
        guard let self else { return }
        while input.isReadyForMoreMediaData {
          let keepGoing: Bool = autoreleasepool {
            if self.isStopped() {
              fail(code: "cancelled", message: "Cancelled", details: nil)
              return false
            }
            guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
              if reader.status == .failed {
                fail(
                  code: "decode",
                  message: reader.error?.localizedDescription ?? "AVAssetReader failed",
                  details: reader.error.map { "\($0)" })
                return false
              }
              finishTrack(input)
              return false
            }
            if reportsProgress && duration > 0 {
              let pts = CMSampleBufferGetPresentationTimeStamp(sample)
              let value = CMTimeGetSeconds(pts) / duration
              if value.isFinite {
                self.events.sendProgress(min(0.99, max(0, value)))
              }
            }
            if !input.append(sample) {
              fail(
                code: "encode",
                message: writer.error?.localizedDescription ?? "append failed",
                details: writer.error.map { "\($0)" })
              return false
            }
            return true
          }
          if !keepGoing {
            return
          }
        }
      }
    }

    if isStopped() {
      fail(code: "cancelled", message: "Cancelled", details: nil)
      return
    }
    events.sendProgress(0.01)
    pumpTrack(output: videoOutput, input: videoInput, reportsProgress: true)
    if let audioOutput, let audioInput {
      pumpTrack(output: audioOutput, input: audioInput, reportsProgress: false)
    }
  }

  private func finish(writer: AVAssetWriter, width: Int, height: Int) {
    if isStopped() {
      requestStop(code: "cancelled", message: "Cancelled", details: nil)
      return
    }
    if writer.status == .failed {
      let message = writer.error?.localizedDescription ?? "finishWriting failed"
      requestStop(code: "mux", message: message, details: writer.error.map { "\($0)" })
      return
    }
    stateLock.lock()
    if failed || didFinish {
      stateLock.unlock()
      return
    }
    didFinish = true
    stateLock.unlock()
    let size = Self.byteSize(at: outputURL.path)
    events.sendProgress(1)
    events.sendCompleted([
      "outputPath": outputURL.path,
      "sizeBytes": size,
      "encoderName": resultEncoderName,
      "codec": options.codec,
      "width": Int64(width),
      "height": Int64(height),
    ])
    onFinished()
  }

  /// Records the terminal failure once, then stops the reader and writer on
  /// `controlQueue`. Safe to call from the media callback and from the main
  /// thread: both return without waiting for `cancelWriting`.
  ///
  /// 只记一次失败，然后在 `controlQueue` 上停掉读写。
  /// 媒体回调和主线程都可以调，两边都不会等 `cancelWriting`。
  private func requestStop(code: String, message: String, details: String?) {
    stateLock.lock()
    if didFinish && !failed {
      stateLock.unlock()
      return
    }
    let first = !failed
    if first {
      failed = true
    }
    stateLock.unlock()
    let tearDown = { [weak self] in
      self?.controlQueue.async {
        guard let self else { return }
        self.removeOutput()
        if first {
          self.events.sendError(code: code, message: message, details: details)
          self.finishOnce()
        }
      }
    }
    // `cancelWriting` syncs onto encodeQueue. If we are inside that callback,
    // hop to the tail of the queue so the callback can return first.
    if DispatchQueue.getSpecific(key: encodeQueueToken) != nil {
      encodeQueue.async(execute: tearDown)
    } else {
      tearDown()
    }
  }

  private func ensureRunning() throws {
    if isStopped() {
      throw PigeonError(code: "cancelled", message: "Cancelled", details: nil)
    }
  }

  private func isStopped() -> Bool {
    cancelled || isCancelled()
  }

  private func removeOutput() {
    stateLock.lock()
    let writer = self.writer
    let reader = self.reader
    self.writer = nil
    self.reader = nil
    stateLock.unlock()
    reader?.cancelReading()
    if let writer, writer.status == .writing {
      writer.cancelWriting()
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }
  }

  private func finishOnce() {
    stateLock.lock()
    let already = didFinish
    didFinish = true
    stateLock.unlock()
    if !already {
      onFinished()
    }
  }

  private static func filesystemPath(_ raw: String) -> String {
    if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
      return url.path
    }
    return raw
  }

  private static func byteSize(at path: String) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let number = attributes[.size] as? NSNumber
    else {
      return 0
    }
    return number.int64Value
  }

  private static func pcmSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func pixelSettings(_ format: OSType) -> [String: Any] {
    [kCVPixelBufferPixelFormatTypeKey as String: format]
  }

  private static func displaySize(of track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  /// 向下取偶数，且至少为 2。编码器和 MP4 都要求偶数边。
  ///
  /// Even size, rounding down, at least 2. Encoders and MP4 require it.
  private static func even(_ value: Int) -> Int {
    let positive = max(0, value)
    return max(2, positive - (positive % 2))
  }

  private static func makeVideoComposition(
    asset: AVAsset,
    track: AVAssetTrack,
    renderSize: CGSize,
    frameDuration: CMTime
  ) -> AVMutableVideoComposition {
    let composition = AVMutableVideoComposition()
    composition.renderSize = renderSize
    composition.frameDuration = frameDuration

    var transform = track.preferredTransform
    let transformed = CGRect(origin: .zero, size: track.naturalSize).applying(transform)
    transform.tx -= transformed.origin.x
    transform.ty -= transformed.origin.y
    let display = CGSize(width: abs(transformed.width), height: abs(transformed.height))
    let scaleX = renderSize.width / max(display.width, 1)
    let scaleY = renderSize.height / max(display.height, 1)
    transform = transform.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(transform, at: .zero)
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]
    return composition
  }

  private struct EncoderAvailability {
    var hardware: Bool
    var any: Bool
  }

  private static func availability(
    _ codecType: CMVideoCodecType, width: Int = 1280, height: Int = 720
  ) -> EncoderAvailability {
    let hardware = probe(codecType, requireHardware: true, width: width, height: height)
    let any =
      hardware || probe(codecType, requireHardware: false, width: width, height: height)
      || codecType == kCMVideoCodecType_H264
    return EncoderAvailability(hardware: hardware, any: any)
  }

  private static func probe(
    _ codecType: CMVideoCodecType, requireHardware: Bool, width: Int, height: Int
  ) -> Bool {
    #if targetEnvironment(simulator)
      if requireHardware {
        return false
      }
    #endif
    if requireHardware {
      #if os(macOS)
        return copySupported(codecType, requireHardware: true, width: width, height: height)
      #else
        if #available(iOS 17.4, *) {
          return copySupported(codecType, requireHardware: true, width: width, height: height)
        }
        return legacyDeviceHardware(codecType)
      #endif
    }
    return copySupported(codecType, requireHardware: false, width: width, height: height)
  }

  private static func legacyDeviceHardware(_ codecType: CMVideoCodecType) -> Bool {
    #if os(iOS) && !targetEnvironment(simulator)
      if codecType == kCMVideoCodecType_HEVC {
        return AVAssetExportSession.allExportPresets().contains(
          AVAssetExportPresetHEVCHighestQuality)
      }
      return codecType == kCMVideoCodecType_H264
    #else
      return false
    #endif
  }

  private static func copySupported(
    _ codecType: CMVideoCodecType, requireHardware: Bool, width: Int, height: Int
  ) -> Bool {
    var specification: CFDictionary?
    if requireHardware {
      #if os(macOS)
        let spec: [CFString: Any] = [
          kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        specification = spec as CFDictionary
      #else
        if #available(iOS 17.4, *) {
          let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
          ]
          specification = spec as CFDictionary
        } else {
          return false
        }
      #endif
    }
    var encoderID: CFString?
    var supported: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(
      width: Int32(max(width, 16)),
      height: Int32(max(height, 16)),
      codecType: codecType,
      encoderSpecification: specification,
      encoderIDOut: &encoderID,
      supportedPropertiesOut: &supported)
    return status == noErr
  }
}

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox NV12 pipeline via AVAssetReader / AVAssetWriter. Audio is dropped.
///
/// VideoToolbox NV12 管线（AVAssetReader / AVAssetWriter），不保留音轨。
final class VideoCompressor {
  private static let encoderName = "VideoToolbox"
  private static let nv12Formats: [OSType] = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
  ]

  private let events: JobEventStream
  private let options: VideoOptionsMsg
  private let outputURL: URL
  private let encodeQueue = DispatchQueue(
    label: "com.xuehua.media_compression.video", qos: .userInitiated)
  private var cancelled = false
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?

  init(events: JobEventStream, inputPath: String, outputPath: String, options: VideoOptionsMsg)
    throws
  {
    if inputPath.hasPrefix("content://") {
      throw PigeonError(
        code: "unsupported", message: "content:// is Android-only", details: nil)
    }
    guard FileManager.default.fileExists(atPath: inputPath) else {
      throw PigeonError(code: "notFound", message: "Video not found: \(inputPath)", details: nil)
    }
    self.events = events
    self.options = options
    self.outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: outputPath) {
      try FileManager.default.removeItem(at: outputURL)
    }
    start(inputURL: URL(fileURLWithPath: inputPath))
  }

  func cancel() {
    cancelled = true
    reader?.cancelReading()
    writer?.cancelWriting()
  }

  static func queryCapabilities() -> VideoCapabilitiesMsg {
    var codecs = ["h264"]
    if isHardwareEncoderAvailable(kCMVideoCodecType_HEVC) {
      codecs.append("h265")
    }
    return VideoCapabilitiesMsg(
      encoderName: encoderName,
      codecs: codecs,
      acceptsContentUri: false)
  }

  private func start(inputURL: URL) {
    let asset = AVURLAsset(url: inputURL)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
      guard let self else { return }
      var error: NSError?
      guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded else {
        self.events.sendError(
          code: "decode",
          message: error?.localizedDescription ?? "Unable to load tracks",
          details: error?.description)
        return
      }
      do {
        try self.configure(asset: asset)
      } catch let pigeon as PigeonError {
        self.events.sendError(
          code: pigeon.code, message: pigeon.message ?? pigeon.code,
          details: pigeon.details.map { "\($0)" })
      } catch {
        self.events.sendError(
          code: "encode", message: error.localizedDescription, details: "\(error)")
      }
    }
  }

  private func configure(asset: AVAsset) throws {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw PigeonError(code: "decode", message: "No video track", details: nil)
    }
    let codec = try resolveCodec()
    let compose = needsComposition
    let outSize = outputSize(for: videoTrack, compose: compose)
    let reader = try AVAssetReader(asset: asset)
    let readerOutput = try attachReaderOutput(
      reader: reader, track: videoTrack, asset: asset, compose: compose, renderSize: outSize)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let writerInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: writerSettings(codec: codec, width: outSize.width, height: outSize.height))
    writerInput.expectsMediaDataInRealTime = false
    writerInput.transform = compose ? .identity : videoTrack.preferredTransform
    guard writer.canAdd(writerInput) else {
      throw PigeonError(code: "encode", message: "Cannot attach writer input", details: nil)
    }
    writer.add(writerInput)

    guard reader.startReading() else {
      throw PigeonError(
        code: "decode",
        message: reader.error?.localizedDescription ?? "AVAssetReader failed",
        details: nil)
    }
    guard writer.startWriting() else {
      throw PigeonError(
        code: "encode",
        message: writer.error?.localizedDescription ?? "AVAssetWriter failed",
        details: nil)
    }
    writer.startSession(atSourceTime: .zero)
    self.reader = reader
    self.writer = writer
    pump(
      reader: reader,
      writer: writer,
      readerOutput: readerOutput,
      writerInput: writerInput,
      duration: CMTimeGetSeconds(asset.duration),
      width: outSize.width,
      height: outSize.height)
  }

  private var needsComposition: Bool {
    (options.maxDimension ?? 0) > 0 || (options.fps ?? 0) > 0
  }

  private func resolveCodec() throws -> AVVideoCodecType {
    switch options.codec {
    case "h265":
      guard Self.isHardwareEncoderAvailable(kCMVideoCodecType_HEVC) else {
        throw PigeonError(
          code: "hardwareUnavailable",
          message: "HEVC hardware encoder is not available",
          details: nil)
      }
      return .hevc
    case "h264":
      return .h264
    default:
      throw PigeonError(
        code: "unsupported", message: "Unknown video codec \(options.codec)", details: nil)
    }
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
      width: Self.even(Int(display.width.rounded())),
      height: Self.even(Int(display.height.rounded()))
    )
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

  private func frameDuration(for track: AVAssetTrack) -> CMTime {
    if let fps = options.fps, fps > 0 {
      return CMTime(value: 1, timescale: CMTimeScale(fps))
    }
    let rate = track.nominalFrameRate
    let timescale = CMTimeScale(max(1, Int((rate > 0 ? rate : 30).rounded())))
    return CMTime(value: 1, timescale: timescale)
  }

  private func writerSettings(codec: AVVideoCodecType, width: Int, height: Int) -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: options.bitrate,
      kVTCompressionPropertyKey_RealTime as String: false,
      kVTCompressionPropertyKey_AllowFrameReordering as String: true,
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    if let fps = options.fps, fps > 0 {
      compression[AVVideoExpectedSourceFrameRateKey] = fps
    }
    if let gop = options.keyframeInterval, gop > 0 {
      compression[AVVideoMaxKeyFrameIntervalKey] = gop
    }
    var settings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]
    #if os(macOS)
      var encoderSpec: [String: Any] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
      ]
      if codec == .hevc {
        encoderSpec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] =
          true
      }
      settings[AVVideoEncoderSpecificationKey] = encoderSpec
    #endif
    return settings
  }

  private func pump(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    readerOutput: AVAssetReaderOutput,
    writerInput: AVAssetWriterInput,
    duration: Double,
    width: Int,
    height: Int
  ) {
    writerInput.requestMediaDataWhenReady(on: encodeQueue) { [weak self] in
      guard let self else { return }
      while writerInput.isReadyForMoreMediaData {
        let keepGoing: Bool = autoreleasepool {
          if self.cancelled {
            writerInput.markAsFinished()
            writer.cancelWriting()
            reader.cancelReading()
            self.events.sendError(code: "cancelled", message: "Cancelled")
            return false
          }
          guard reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() else {
            writerInput.markAsFinished()
            if reader.status == .failed {
              writer.cancelWriting()
              self.events.sendError(
                code: "decode",
                message: reader.error?.localizedDescription ?? "AVAssetReader failed",
                details: reader.error.map { "\($0)" })
              return false
            }
            writer.finishWriting {
              self.finish(writer: writer, width: width, height: height)
            }
            return false
          }
          let pts = CMSampleBufferGetPresentationTimeStamp(sample)
          if duration > 0 {
            self.events.sendProgress(min(1, CMTimeGetSeconds(pts) / duration))
          }
          if !writerInput.append(sample) {
            writerInput.markAsFinished()
            writer.cancelWriting()
            reader.cancelReading()
            self.events.sendError(
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

  private func finish(writer: AVAssetWriter, width: Int, height: Int) {
    if cancelled {
      events.sendError(code: "cancelled", message: "Cancelled")
      return
    }
    if writer.status == .failed {
      events.sendError(
        code: "mux",
        message: writer.error?.localizedDescription ?? "finishWriting failed",
        details: writer.error.map { "\($0)" })
      return
    }
    let size =
      (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
    events.sendCompleted([
      "outputPath": outputURL.path,
      "sizeBytes": size,
      "encoderName": Self.encoderName,
      "codec": options.codec,
      "width": Int64(width),
      "height": Int64(height),
    ])
  }

  private static func pixelSettings(_ format: OSType) -> [String: Any] {
    [kCVPixelBufferPixelFormatTypeKey as String: format]
  }

  private static func displaySize(of track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  private static func even(_ value: Int) -> Int {
    max(2, (value / 2) * 2)
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

  private static func isHardwareEncoderAvailable(_ codecType: CMVideoCodecType) -> Bool {
    var spec: [CFString: Any] = [:]
    #if os(macOS)
      spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
      spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
    #endif
    var encoderID: CFString?
    var supported: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(
      width: 1920,
      height: 1080,
      codecType: codecType,
      encoderSpecification: spec.isEmpty ? nil : (spec as CFDictionary),
      encoderIDOut: &encoderID,
      supportedPropertiesOut: &supported)
    if status == noErr {
      return true
    }
    #if os(iOS)
      if codecType == kCMVideoCodecType_HEVC {
        return AVAssetExportSession.allExportPresets().contains(
          AVAssetExportPresetHEVCHighestQuality)
      }
    #endif
    return false
  }
}

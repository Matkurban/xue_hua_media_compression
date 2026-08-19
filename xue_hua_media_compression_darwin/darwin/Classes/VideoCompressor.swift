import AVFoundation
import CoreMedia
import Foundation

/// VideoToolbox-backed AVAssetReader / AVAssetWriter pipeline. Audio is dropped.
///
/// 基于 VideoToolbox 的 AVAssetReader/Writer 管线，不保留音轨。
final class VideoCompressor {
  private let events: JobEventStream
  private let options: VideoOptionsMsg
  private let outputURL: URL
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
    return VideoCapabilitiesMsg(
      encoderName: "AVAssetWriter",
      codecs: ["h264", "h265"],
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
        self.events.sendError(code: "encode", message: error.localizedDescription, details: "\(error)")
      }
    }
  }

  private func configure(asset: AVAsset) throws {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw PigeonError(code: "decode", message: "No video track", details: nil)
    }
    let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    let srcWidth = abs(natural.width)
    let srcHeight = abs(natural.height)
    var outWidth = Int(srcWidth)
    var outHeight = Int(srcHeight)
    if let maxDimension = options.maxDimension, maxDimension > 0 {
      let longest = max(srcWidth, srcHeight)
      if longest > CGFloat(maxDimension) {
        let scale = CGFloat(maxDimension) / longest
        outWidth = max(2, Int(srcWidth * scale) / 2 * 2)
        outHeight = max(2, Int(srcHeight * scale) / 2 * 2)
      }
    }

    let codec: AVVideoCodecType
    switch options.codec {
    case "h265":
      codec = .hevc
    case "h264":
      codec = .h264
    default:
      throw PigeonError(
        code: "unsupported", message: "Unknown video codec \(options.codec)", details: nil)
    }

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else {
      throw PigeonError(code: "decode", message: "Cannot attach reader output", details: nil)
    }
    reader.add(readerOutput)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: options.bitrate
    ]
    if let fps = options.fps, fps > 0 {
      compression[AVVideoExpectedSourceFrameRateKey] = fps
    }
    if let gop = options.keyframeInterval, gop > 0 {
      compression[AVVideoMaxKeyFrameIntervalKey] = gop
    }
    let writerSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: outWidth,
      AVVideoHeightKey: outHeight,
      AVVideoCompressionPropertiesKey: compression,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
    writerInput.expectsMediaDataInRealTime = false
    writerInput.transform = videoTrack.preferredTransform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: outWidth,
        kCVPixelBufferHeightKey as String: outHeight,
      ])
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

    let duration = CMTimeGetSeconds(asset.duration)
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    writerInput.requestMediaDataWhenReady(on: DispatchQueue.global(qos: .userInitiated)) {
      [weak self] in
      guard let self else { return }
      while writerInput.isReadyForMoreMediaData {
        if self.cancelled {
          writerInput.markAsFinished()
          writer.cancelWriting()
          reader.cancelReading()
          self.events.sendError(code: "cancelled", message: "Cancelled")
          return
        }
        guard let sample = readerOutput.copyNextSampleBuffer() else {
          writerInput.markAsFinished()
          writer.finishWriting {
            if self.cancelled {
              self.events.sendError(code: "cancelled", message: "Cancelled")
              return
            }
            if writer.status == .failed {
              self.events.sendError(
                code: "mux",
                message: writer.error?.localizedDescription ?? "finishWriting failed",
                details: writer.error.map { "\($0)" })
              return
            }
            let size =
              (try? FileManager.default.attributesOfItem(atPath: self.outputURL.path)[.size]
                as? Int64) ?? 0
            self.events.sendCompleted([
              "outputPath": self.outputURL.path,
              "sizeBytes": size,
              "encoderName": "AVAssetWriter",
              "codec": self.options.codec,
              "width": Int64(outWidth),
              "height": Int64(outHeight),
            ])
          }
          return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if duration > 0 {
          self.events.sendProgress(min(1, CMTimeGetSeconds(pts) / duration))
        }
        var outputBuffer: CVPixelBuffer?
        if outWidth != Int(srcWidth) || outHeight != Int(srcHeight) {
          outputBuffer = self.scale(
            pixelBuffer: pixelBuffer,
            width: outWidth,
            height: outHeight,
            context: ciContext,
            pool: adaptor.pixelBufferPool)
        } else {
          outputBuffer = pixelBuffer
        }
        if let outputBuffer {
          adaptor.append(outputBuffer, withPresentationTime: pts)
        }
      }
    }
  }

  private func scale(
    pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    context: CIContext,
    pool: CVPixelBufferPool?
  ) -> CVPixelBuffer? {
    var output: CVPixelBuffer?
    if let pool {
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
    }
    if output == nil {
      CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_32BGRA, nil, &output)
    }
    guard let output else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let scaled = image.transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(width) / image.extent.width,
        y: CGFloat(height) / image.extent.height))
    context.render(scaled, to: output)
    return output
  }
}

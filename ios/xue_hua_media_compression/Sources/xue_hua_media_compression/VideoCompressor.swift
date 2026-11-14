import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware/VideoToolbox video transcoder for iOS.
final class VideoCompressor: @unchecked Sendable {
  struct CodecProbe {
    let hardware: Bool
    let software: Bool
  }

  private let lock = NSLock()
  private let inputPath: String
  private let outputPath: String
  private let options: VideoOptionsMsg
  private let relay: JobFlutterEventRelay
  private let onFinished: @Sendable () -> Void

  private let workQueue = DispatchQueue(
    label: "com.xuehua.media_compression.ios.video.work",
    qos: .userInitiated
  )
  private let videoPumpQueue = DispatchQueue(
    label: "com.xuehua.media_compression.ios.video.pump",
    qos: .userInitiated
  )
  private let audioPumpQueue = DispatchQueue(
    label: "com.xuehua.media_compression.ios.audio.pump",
    qos: .userInitiated
  )

  private var cancelled = false
  private var finished = false
  private var asset: AVURLAsset?
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?
  private var outputURL: URL?

  init(
    inputPath: String,
    outputPath: String,
    options: VideoOptionsMsg,
    relay: JobFlutterEventRelay,
    onFinished: @escaping @Sendable () -> Void
  ) {
    self.inputPath = inputPath
    self.outputPath = outputPath
    self.options = options
    self.relay = relay
    self.onFinished = onFinished
  }

  static func queryCapabilities() -> VideoCapabilitiesMsg {
    let h264 = probe(codec: "h264")
    let h265 = probe(codec: "h265")

    var codecs: [String] = []
    if h264.hardware || h264.software {
      codecs.append("h264")
    }
    if h265.hardware || h265.software {
      codecs.append("h265")
    }

    let hasHardware = h264.hardware || h265.hardware
    return VideoCapabilitiesMsg(
      encoderName: hasHardware ? "VideoToolboxHW" : nil,
      codecs: codecs,
      acceptsContentUri: false
    )
  }

  func start() {
    let rawInput = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawOutput = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if rawInput.isEmpty || rawOutput.isEmpty {
      fail(code: "io", message: "Input or output path is empty")
      return
    }
    if rawInput.hasPrefix("content://") {
      fail(code: "unsupported", message: "content:// URIs are not supported on iOS")
      return
    }

    let codec = options.codec.lowercased()
    guard codec == "h264" || codec == "h265" else {
      fail(code: "unsupported", message: "Unsupported video codec: \(options.codec)")
      return
    }

    let probeResult = Self.probe(codec: codec)
    guard probeResult.hardware || probeResult.software else {
      fail(code: "unsupported", message: "No encoder available for codec: \(codec)")
      return
    }
    let useHardware = probeResult.hardware

    let inURL: URL
    let outURL: URL
    do {
      inURL = try ImageCompressor.fileURL(from: rawInput, codeOnUriError: "unsupported")
      outURL = try ImageCompressor.fileURL(from: rawOutput, codeOnUriError: "unsupported")
    } catch let err as PigeonError {
      fail(code: err.code ?? "unsupported", message: err.message ?? "Invalid URL")
      return
    } catch {
      fail(code: "unsupported", message: error.localizedDescription)
      return
    }

    var inIsDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: inURL.path, isDirectory: &inIsDir) else {
      fail(code: "notFound", message: "Input file does not exist: \(inURL.path)")
      return
    }
    if inIsDir.boolValue {
      fail(code: "io", message: "Input path is a directory: \(inURL.path)")
      return
    }

    var outIsDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: outURL.path, isDirectory: &outIsDir),
       outIsDir.boolValue
    {
      fail(code: "io", message: "Output path is a directory: \(outURL.path)")
      return
    }

    lock.lock()
    if cancelled {
      lock.unlock()
      failCancelled(removing: outURL)
      return
    }
    self.outputURL = outURL
    let urlAsset = AVURLAsset(
      url: inURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    self.asset = urlAsset
    lock.unlock()

    relay.sendProgress(0.0)

    let keys = ["tracks", "duration", "playable"]
    urlAsset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
      guard let self else { return }
      self.workQueue.async {
        self.prepareAndRun(
          asset: urlAsset,
          outURL: outURL,
          codec: codec,
          useHardware: useHardware
        )
      }
    }
  }

  func cancel() {
    lock.lock()
    if cancelled || finished {
      lock.unlock()
      return
    }
    cancelled = true
    let activeAsset = asset
    let activeReader = reader
    let activeWriter = writer
    let targetURL = outputURL
    lock.unlock()

    activeAsset?.cancelLoading()
    // Dispatch reader/writer cancellation off the platform caller thread to avoid
    // blocking Dart while VideoToolbox winds down active sample buffers.
    workQueue.async {
      activeReader?.cancelReading()
      activeWriter?.cancelWriting()
      if let targetURL {
        ImageCompressor.removeFile(at: targetURL)
      }
    }
  }

  private func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  private func prepareAndRun(
    asset: AVURLAsset,
    outURL: URL,
    codec: String,
    useHardware: Bool
  ) {
    if isCancelled() {
      failCancelled(removing: outURL)
      return
    }

    for key in ["tracks", "duration", "playable"] {
      var err: NSError?
      let status = asset.statusOfValue(forKey: key, error: &err)
      if status == .cancelled {
        failCancelled(removing: outURL)
        return
      }
      if status == .failed {
        fail(
          code: "decode",
          message: err?.localizedDescription ?? "Failed to inspect source video (\(key))"
        )
        return
      }
    }

    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      fail(code: "decode", message: "No video track found in input file")
      return
    }

    let naturalSize = videoTrack.naturalSize
    let preferredTransform = videoTrack.preferredTransform
    let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let sourceWidth = abs(transformedRect.width)
    let sourceHeight = abs(transformedRect.height)
    guard sourceWidth > 0, sourceHeight > 0 else {
      fail(code: "decode", message: "Invalid source video dimensions")
      return
    }

    var scaledWidth = Double(sourceWidth)
    var scaledHeight = Double(sourceHeight)
    if let maxDim = options.maxDimension, maxDim > 0 {
      let limit = Double(maxDim)
      let longest = max(scaledWidth, scaledHeight)
      if longest > limit {
        let scale = limit / longest
        scaledWidth *= scale
        scaledHeight *= scale
      }
    }

    let targetWidth = max(2, (Int(floor(scaledWidth)) / 2) * 2)
    let targetHeight = max(2, (Int(floor(scaledHeight)) / 2) * 2)

    do {
      try FileManager.default.createDirectory(
        at: outURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      if FileManager.default.fileExists(atPath: outURL.path) {
        try FileManager.default.removeItem(at: outURL)
      }
    } catch {
      fail(
        code: "io",
        message: "Failed preparing output path: \(error.localizedDescription)"
      )
      return
    }

    let assetReader: AVAssetReader
    let assetWriter: AVAssetWriter
    do {
      assetReader = try AVAssetReader(asset: asset)
      assetWriter = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    } catch {
      ImageCompressor.removeFile(at: outURL)
      fail(code: "mux", message: "Failed creating reader/writer: \(error.localizedDescription)")
      return
    }

    let videoComposition = Self.buildComposition(
      asset: asset,
      videoTrack: videoTrack,
      preferredTransform: preferredTransform,
      transformedRect: transformedRect,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      requestedFps: options.fps
    )

    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: [videoTrack],
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ]
    )
    videoOutput.videoComposition = videoComposition
    videoOutput.alwaysCopiesSampleData = false

    guard assetReader.canAdd(videoOutput) else {
      ImageCompressor.removeFile(at: outURL)
      fail(code: "decode", message: "Cannot attach video reader output")
      return
    }
    assetReader.add(videoOutput)

    let videoSettings = Self.writerVideoSettings(
      codec: codec,
      width: targetWidth,
      height: targetHeight,
      bitrate: Int(max(10_000, options.bitrate)),
      keyframeInterval: options.keyframeInterval.map { Int($0) }
    )
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false

    guard assetWriter.canAdd(videoInput) else {
      ImageCompressor.removeFile(at: outURL)
      fail(code: "encode", message: "Cannot configure video encoder for \(codec)")
      return
    }
    assetWriter.add(videoInput)

    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    if options.keepAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
      let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      let aOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
      aOutput.alwaysCopiesSampleData = false
      if assetReader.canAdd(aOutput) {
        let audioParams = Self.audioFormatParams(for: audioTrack)
        let aacSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: audioParams.sampleRate,
          AVNumberOfChannelsKey: audioParams.channels,
          AVEncoderBitRateKey: 128_000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        aInput.expectsMediaDataInRealTime = false
        if assetWriter.canAdd(aInput) {
          assetReader.add(aOutput)
          assetWriter.add(aInput)
          audioOutput = aOutput
          audioInput = aInput
        }
      }
    }

    lock.lock()
    if cancelled {
      lock.unlock()
      ImageCompressor.removeFile(at: outURL)
      failCancelled(removing: outURL)
      return
    }
    self.reader = assetReader
    self.writer = assetWriter
    lock.unlock()

    guard assetWriter.startWriting() else {
      ImageCompressor.removeFile(at: outURL)
      fail(
        code: "mux",
        message: assetWriter.error?.localizedDescription ?? "Unable to start MP4 writer"
      )
      return
    }
    guard assetReader.startReading() else {
      assetWriter.cancelWriting()
      ImageCompressor.removeFile(at: outURL)
      fail(
        code: "decode",
        message: assetReader.error?.localizedDescription ?? "Unable to read video asset"
      )
      return
    }
    assetWriter.startSession(atSourceTime: .zero)

    var durationSeconds = asset.duration.seconds
    if !durationSeconds.isFinite || durationSeconds <= 0 {
      durationSeconds = videoTrack.timeRange.duration.seconds
    }

    let pumpGroup = DispatchGroup()

    pumpGroup.enter()
    var videoCompleted = false
    videoInput.requestMediaDataWhenReady(on: videoPumpQueue) { [weak self] in
      guard let self else {
        if !videoCompleted {
          videoCompleted = true
          videoInput.markAsFinished()
          pumpGroup.leave()
        }
        return
      }
      if videoCompleted { return }
      while videoInput.isReadyForMoreMediaData {
        if self.isCancelled() || assetWriter.status == .failed || assetReader.status == .failed {
          videoCompleted = true
          videoInput.markAsFinished()
          pumpGroup.leave()
          return
        }
        if let sample = videoOutput.copyNextSampleBuffer() {
          let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
          if durationSeconds.isFinite && durationSeconds > 0 && pts.isFinite {
            let ratio = max(0.0, min(0.99, pts / durationSeconds))
            self.relay.sendProgress(ratio)
          }
          if !videoInput.append(sample) {
            videoCompleted = true
            videoInput.markAsFinished()
            pumpGroup.leave()
            return
          }
        } else {
          videoCompleted = true
          videoInput.markAsFinished()
          pumpGroup.leave()
          return
        }
      }
    }

    if let aOutput = audioOutput, let aInput = audioInput {
      pumpGroup.enter()
      var audioCompleted = false
      aInput.requestMediaDataWhenReady(on: audioPumpQueue) { [weak self] in
        guard let self else {
          if !audioCompleted {
            audioCompleted = true
            aInput.markAsFinished()
            pumpGroup.leave()
          }
          return
        }
        if audioCompleted { return }
        while aInput.isReadyForMoreMediaData {
          if self.isCancelled() || assetWriter.status == .failed || assetReader.status == .failed {
            audioCompleted = true
            aInput.markAsFinished()
            pumpGroup.leave()
            return
          }
          if let sample = aOutput.copyNextSampleBuffer() {
            if !aInput.append(sample) {
              audioCompleted = true
              aInput.markAsFinished()
              pumpGroup.leave()
              return
            }
          } else {
            audioCompleted = true
            aInput.markAsFinished()
            pumpGroup.leave()
            return
          }
        }
      }
    }

    let encoderLabel = (useHardware ? "VideoToolboxHW:" : "VideoToolbox:")
      + (codec == "h265" ? "H265" : "H264")

    pumpGroup.notify(queue: workQueue) { [weak self] in
      guard let self else { return }
      if self.isCancelled() {
        assetReader.cancelReading()
        assetWriter.cancelWriting()
        self.failCancelled(removing: outURL)
        return
      }
      if assetReader.status == .failed {
        assetWriter.cancelWriting()
        ImageCompressor.removeFile(at: outURL)
        self.fail(
          code: "decode",
          message: assetReader.error?.localizedDescription ?? "Failed reading video frames"
        )
        return
      }
      if assetWriter.status == .failed {
        assetReader.cancelReading()
        ImageCompressor.removeFile(at: outURL)
        self.fail(
          code: "encode",
          message: assetWriter.error?.localizedDescription ?? "Failed encoding video frames"
        )
        return
      }

      assetWriter.finishWriting { [weak self] in
        guard let self else { return }
        self.workQueue.async {
          if self.isCancelled() {
            self.failCancelled(removing: outURL)
            return
          }
          guard assetWriter.status == .completed else {
            ImageCompressor.removeFile(at: outURL)
            self.fail(
              code: "mux",
              message: assetWriter.error?.localizedDescription ?? "Failed writing output MP4"
            )
            return
          }
          do {
            let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
            let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard sizeBytes > 0 else {
              ImageCompressor.removeFile(at: outURL)
              self.fail(code: "mux", message: "Output MP4 file is empty")
              return
            }
            self.relay.sendProgress(1.0)
            let result = VideoCompressResultMsg(
              outputPath: outURL.path,
              sizeBytes: sizeBytes,
              encoderName: encoderLabel,
              codec: codec,
              width: Int64(targetWidth),
              height: Int64(targetHeight)
            )
            self.complete(result: result)
          } catch {
            ImageCompressor.removeFile(at: outURL)
            self.fail(
              code: "io",
              message: "Failed reading output size: \(error.localizedDescription)"
            )
          }
        }
      }
    }
  }

  private func complete(result: VideoCompressResultMsg) {
    lock.lock()
    let alreadyFinished = finished
    finished = true
    reader = nil
    writer = nil
    asset = nil
    lock.unlock()
    guard !alreadyFinished else { return }
    relay.sendVideoCompleted(result)
    onFinished()
  }

  private func failCancelled(removing url: URL) {
    ImageCompressor.removeFile(at: url)
    fail(code: "cancelled", message: "Job cancelled")
  }

  private func fail(code: String, message: String) {
    lock.lock()
    let alreadyFinished = finished
    finished = true
    reader = nil
    writer = nil
    asset = nil
    lock.unlock()
    guard !alreadyFinished else { return }
    relay.sendError(code: code, message: message)
    onFinished()
  }

  private static func buildComposition(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    preferredTransform: CGAffineTransform,
    transformedRect: CGRect,
    targetWidth: Int,
    targetHeight: Int,
    requestedFps: Int64?
  ) -> AVMutableVideoComposition {
    let sourceFps = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : 30.0
    let targetFps: Double
    if let req = requestedFps, req > 0 {
      targetFps = max(1.0, min(Double(req), sourceFps))
    } else {
      targetFps = max(1.0, sourceFps)
    }

    let composition = AVMutableVideoComposition()
    composition.frameDuration = CMTime(seconds: 1.0 / targetFps, preferredTimescale: 600)
    composition.renderSize = CGSize(width: targetWidth, height: targetHeight)

    let instruction = AVMutableVideoCompositionInstruction()
    var duration = asset.duration
    if !duration.isValid || duration.seconds <= 0 {
      duration = videoTrack.timeRange.duration
    }
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    let translateToOrigin = CGAffineTransform(
      translationX: -transformedRect.origin.x,
      y: -transformedRect.origin.y
    )
    let scale = CGAffineTransform(
      scaleX: CGFloat(targetWidth) / max(1.0, abs(transformedRect.width)),
      y: CGFloat(targetHeight) / max(1.0, abs(transformedRect.height))
    )
    let finalTransform = preferredTransform
      .concatenating(translateToOrigin)
      .concatenating(scale)
    layerInstruction.setTransform(finalTransform, at: .zero)

    instruction.layerInstructions = [layerInstruction]
    composition.instructions = [instruction]
    return composition
  }

  private static func writerVideoSettings(
    codec: String,
    width: Int,
    height: Int,
    bitrate: Int,
    keyframeInterval: Int?
  ) -> [String: Any] {
    var compressionProps: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate
    ]
    if let keyframeInterval, keyframeInterval > 0 {
      compressionProps[AVVideoMaxKeyFrameIntervalKey] = keyframeInterval
    }
    return [
      AVVideoCodecKey: codec == "h265" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compressionProps,
    ]
  }

  private static func audioFormatParams(
    for audioTrack: AVAssetTrack
  ) -> (sampleRate: Double, channels: Int) {
    guard let desc = audioTrack.formatDescriptions.first else {
      return (44_100, 2)
    }
    let formatDesc = desc as! CMAudioFormatDescription
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
      return (44_100, 2)
    }
    let rawRate = asbd.mSampleRate
    let sampleRate: Double
    if [8_000.0, 11_025.0, 12_000.0, 16_000.0, 22_050.0, 24_000.0, 32_000.0, 44_100.0, 48_000.0]
      .contains(rawRate)
    {
      sampleRate = rawRate
    } else {
      sampleRate = 44_100
    }
    let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
    return (sampleRate, channels)
  }

  private static func probe(codec: String) -> CodecProbe {
    let cmType: CMVideoCodecType
    switch codec {
    case "h264":
      cmType = kCMVideoCodecType_H264
    case "h265":
      cmType = kCMVideoCodecType_HEVC
    default:
      return CodecProbe(hardware: false, software: false)
    }

    let hardware: Bool
    #if targetEnvironment(simulator)
      hardware = false
    #else
      if #available(iOS 17.4, *) {
        hardware = copySupported(codecType: cmType, requireHardware: true)
      } else {
        hardware = legacyDeviceHardware(codec: codec)
      }
    #endif

    let software: Bool
    if #available(iOS 17.4, *) {
      software = copySupported(codecType: cmType, requireHardware: false)
    } else {
      software = codec == "h264" || legacyDeviceHardware(codec: codec)
    }

    return CodecProbe(hardware: hardware, software: software)
  }

  private static func legacyDeviceHardware(codec: String) -> Bool {
    if codec == "h264" {
      return true
    }
    return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
  }

  @available(iOS 17.4, *)
  private static func copySupported(
    codecType: CMVideoCodecType,
    requireHardware: Bool
  ) -> Bool {
    let spec: [String: Any] = requireHardware
      ? [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
      ]
      : [:]
    var props: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(
      width: 1920,
      height: 1080,
      codecType: codecType,
      encoderSpecification: spec.isEmpty ? nil : (spec as CFDictionary),
      encoderIDOut: nil,
      supportedPropertiesOut: &props
    )
    return status == noErr
  }
}

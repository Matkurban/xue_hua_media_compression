import CoreGraphics
import Foundation
import ImageIO

enum ImageCompressor {
  private static let readableFormats: [(String, [String])] = [
    ("jpeg", ["public.jpeg"]),
    ("png", ["public.png"]),
    ("webp", ["org.webmproject.webp"]),
    ("heic", ["public.heic", "public.heif"]),
    ("avif", ["public.avif"]),
    ("gif", ["com.compuserve.gif"]),
  ]

  private static let writableFormats: [(String, String)] = [
    ("jpeg", "public.jpeg"),
    ("png", "public.png"),
    ("heic", "public.heic"),
    ("webp", "org.webmproject.webp"),
  ]

  static func queryCapabilities() -> ImageCapabilitiesMsg {
    let sourceTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    let destTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    let inputs = readableFormats.compactMap { name, utis in
      utis.contains(where: sourceTypes.contains) ? name : nil
    }
    let outputs = writableFormats.compactMap { name, uti in
      destTypes.contains(uti) ? name : nil
    }

    return ImageCapabilitiesMsg(inputFormats: inputs, outputFormats: outputs)
  }

  static func compress(
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg,
    reportProgress: (Double) -> Void,
    isCancelled: () -> Bool
  ) throws -> ImageCompressResultMsg {
    let format = options.format.lowercased()
    guard let destinationUTI = destinationUTI(for: format) else {
      throw PigeonError(
        code: "unsupported",
        message: "Unsupported output image format: \(options.format)",
        details: nil
      )
    }

    let destTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    guard destTypes.contains(destinationUTI) else {
      throw PigeonError(
        code: "unsupported",
        message: "Image encoder not available for format: \(format)",
        details: nil
      )
    }

    if destination.kind != 0 && destination.kind != 1 {
      throw PigeonError(
        code: "unsupported",
        message: "Unsupported destination kind: \(destination.kind)",
        details: nil
      )
    }

    let outputURL: URL?
    if destination.kind == 1 {
      guard let rawOut = destination.path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOut.isEmpty
      else {
        throw PigeonError(code: "io", message: "Output path is empty", details: nil)
      }
      let url = try fileURL(from: rawOut, codeOnUriError: "unsupported")
      var outIsDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &outIsDir),
         outIsDir.boolValue
      {
        throw PigeonError(
          code: "io",
          message: "Output path is a directory: \(url.path)",
          details: nil
        )
      }
      outputURL = url
    } else {
      outputURL = nil
    }

    if isCancelled() {
      throw PigeonError(code: "cancelled", message: "Job cancelled", details: nil)
    }

    let imageSource: CGImageSource
    switch source.kind {
    case 0:
      guard let rawBytes = source.bytes, !rawBytes.isEmpty else {
        throw PigeonError(code: "decode", message: "Input bytes are empty", details: nil)
      }
      let data = Data(rawBytes) as CFData
      guard let src = CGImageSourceCreateWithData(data, nil) else {
        throw PigeonError(code: "decode", message: "Unable to read image data", details: nil)
      }
      imageSource = src
    case 1:
      guard let rawPath = source.path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
      else {
        throw PigeonError(code: "io", message: "Input path is empty", details: nil)
      }
      if rawPath.hasPrefix("content://") {
        throw PigeonError(
          code: "unsupported",
          message: "content:// URIs are not supported on macOS",
          details: nil
        )
      }
      let inputURL = try fileURL(from: rawPath, codeOnUriError: "unsupported")
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
        throw PigeonError(
          code: "notFound",
          message: "Input file does not exist: \(inputURL.path)",
          details: nil
        )
      }
      if isDir.boolValue {
        throw PigeonError(
          code: "io",
          message: "Input path is a directory: \(inputURL.path)",
          details: nil
        )
      }
      guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
        throw PigeonError(
          code: "decode",
          message: "Unable to open image file: \(inputURL.path)",
          details: nil
        )
      }
      imageSource = src
    default:
      throw PigeonError(
        code: "unsupported",
        message: "Unsupported source kind: \(source.kind)",
        details: nil
      )
    }

    guard CGImageSourceGetCount(imageSource) > 0 else {
      throw PigeonError(code: "decode", message: "Invalid or corrupt image source", details: nil)
    }

    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

    if pixelWidth > 0 && pixelHeight > 0 {
      reportProgress(0.25)
    }

    let cgImage: CGImage
    var bakedUpright = false
    if let maxDim = options.maxDimension, maxDim > 0 {
      let limit = Int(maxDim)
      let longest = max(pixelWidth, pixelHeight)
      if longest > limit || longest == 0 {
        let thumbOptions: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceShouldCacheImmediately: false,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
          imageSource,
          0,
          thumbOptions as CFDictionary
        ) else {
          throw PigeonError(code: "decode", message: "Failed to decode scaled image", details: nil)
        }
        cgImage = decoded
        bakedUpright = true
      } else if !options.keepMetadata && rawOrientation != 1 {
        cgImage = try decodeUprightImage(from: imageSource, maxSize: longest)
        bakedUpright = true
      } else {
        guard let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
          throw PigeonError(code: "decode", message: "Failed to decode image", details: nil)
        }
        cgImage = decoded
      }
    } else if !options.keepMetadata && rawOrientation != 1 && max(pixelWidth, pixelHeight) > 0 {
      cgImage = try decodeUprightImage(
        from: imageSource,
        maxSize: max(pixelWidth, pixelHeight)
      )
      bakedUpright = true
    } else {
      guard let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw PigeonError(code: "decode", message: "Failed to decode image", details: nil)
      }
      cgImage = decoded
    }

    if isCancelled() {
      throw PigeonError(code: "cancelled", message: "Job cancelled", details: nil)
    }

    // Emit positive mid-flight progress before running the heavy encode pass so
    // cancellation watchers and progress subscribers observe active compression.
    reportProgress(0.5)

    let encodedData = NSMutableData()
    guard let imageDestination = CGImageDestinationCreateWithData(
      encodedData as CFMutableData,
      destinationUTI as CFString,
      1,
      nil
    ) else {
      throw PigeonError(
        code: "encode",
        message: "Failed to initialize encoder for \(format)",
        details: nil
      )
    }

    var encodeProperties: [CFString: Any] = options.keepMetadata ? (properties ?? [:]) : [:]
    if bakedUpright {
      encodeProperties.removeValue(forKey: kCGImagePropertyOrientation)
      if var tiff = encodeProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
        encodeProperties[kCGImagePropertyTIFFDictionary] = tiff
      }
    }
    let normalizedQuality = Double(max(1, min(100, options.quality))) / 100.0
    encodeProperties[kCGImageDestinationLossyCompressionQuality] = normalizedQuality

    CGImageDestinationAddImage(imageDestination, cgImage, encodeProperties as CFDictionary)
    guard CGImageDestinationFinalize(imageDestination) else {
      throw PigeonError(code: "encode", message: "Failed to finalize \(format) encode", details: nil)
    }

    if isCancelled() {
      if let url = outputURL {
        removeFile(at: url)
      }
      throw PigeonError(code: "cancelled", message: "Job cancelled", details: nil)
    }

    let outWidth = Int64(cgImage.width)
    let outHeight = Int64(cgImage.height)
    let outputData = encodedData as Data

    if let url = outputURL {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true,
          attributes: nil
        )
        try outputData.write(to: url, options: .atomic)
      } catch {
        removeFile(at: url)
        throw PigeonError(
          code: "io",
          message: "Failed to write output image: \(error.localizedDescription)",
          details: nil
        )
      }
      if isCancelled() {
        removeFile(at: url)
        throw PigeonError(code: "cancelled", message: "Job cancelled", details: nil)
      }
      return ImageCompressResultMsg(
        bytes: nil,
        outputPath: url.path,
        sizeBytes: Int64(outputData.count),
        format: format,
        width: outWidth,
        height: outHeight
      )
    }

    return ImageCompressResultMsg(
      bytes: [UInt8](outputData),
      outputPath: nil,
      sizeBytes: Int64(outputData.count),
      format: format,
      width: outWidth,
      height: outHeight
    )
  }

  static func removeFile(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  static func fileURL(from raw: String, codeOnUriError: String) throws -> URL {
    if raw.hasPrefix("file://") {
      guard let url = URL(string: raw), url.isFileURL else {
        throw PigeonError(code: codeOnUriError, message: "Invalid file URI: \(raw)", details: nil)
      }
      return url
    }
    if let schemeRange = raw.range(of: "://"),
       !raw[..<schemeRange.lowerBound].contains("/")
    {
      throw PigeonError(
        code: codeOnUriError,
        message: "Unsupported URI scheme: \(raw)",
        details: nil
      )
    }
    return URL(fileURLWithPath: raw)
  }

  private static func decodeUprightImage(from source: CGImageSource, maxSize: Int) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: false,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSize,
    ]
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw PigeonError(code: "decode", message: "Failed to decode upright image", details: nil)
    }
    return decoded
  }

  private static func destinationUTI(for format: String) -> String? {
    return writableFormats.first { $0.0 == format }?.1
  }
}

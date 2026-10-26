#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif
import Foundation
import ImageIO

enum ImageCompressor {
  static func queryCapabilities() -> ImageCapabilitiesMsg {
    var inputs = ["jpeg", "png", "gif"]
    if canDecode("public.heic") || canDecode("public.heif") { inputs.append("heic") }
    if canDecode("org.webmproject.webp") { inputs.append("webp") }
    if canDecode("public.avif") { inputs.append("avif") }

    var outputs = ["jpeg", "png"]
    if canEncode("public.heic") || canEncode("public.heif") { outputs.append("heic") }
    if canEncode("org.webmproject.webp") { outputs.append("webp") }
    return ImageCapabilitiesMsg(inputFormats: inputs, outputFormats: outputs)
  }

  static func removeFile(at path: String) {
    guard !path.isEmpty else { return }
    let resolved = filesystemPath(path)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
      return
    }
    if isDirectory.boolValue { return }
    try? FileManager.default.removeItem(atPath: resolved)
  }

  static func compress(
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg
  ) throws -> [String: Any?] {
    let format = options.format
    guard let uti = destinationUTI(format), canEncode(uti as String) else {
      throw PigeonError(
        code: "unsupported",
        message: "Darwin cannot encode \(format)",
        details: nil)
    }

    let cgSource = try makeSource(source)
    let image = try decode(cgSource, maxDimension: options.maxDimension.map { Int($0) })
    let quality = Double(options.quality) / 100.0
    var destProperties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality
    ]
    if options.keepMetadata {
      for (key, value) in metadataProperties(from: cgSource) {
        destProperties[key] = value
      }
    }

    switch destination.kind {
    case 0:
      let data = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
        throw PigeonError(code: "encode", message: "CGImageDestinationCreateWithData failed", details: nil)
      }
      CGImageDestinationAddImage(dest, image, destProperties as CFDictionary)
      guard CGImageDestinationFinalize(dest) else {
        throw PigeonError(code: "encode", message: "CGImageDestinationFinalize failed", details: nil)
      }
      let bytes = FlutterStandardTypedData(bytes: data as Data)
      return [
        "bytes": bytes,
        "sizeBytes": Int64(data.length),
        "format": format,
        "width": Int64(image.width),
        "height": Int64(image.height),
      ]
    case 1:
      guard let rawPath = destination.path, !rawPath.isEmpty else {
        throw PigeonError(code: "io", message: "Missing destination path", details: nil)
      }
      if rawPath.hasPrefix("content://") {
        throw PigeonError(
          code: "unsupported",
          message: "content:// is Android-only",
          details: nil)
      }
      let path = filesystemPath(rawPath)
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
        removeFile(at: path)
        throw PigeonError(code: "encode", message: "CGImageDestinationCreateWithURL failed", details: nil)
      }
      CGImageDestinationAddImage(dest, image, destProperties as CFDictionary)
      guard CGImageDestinationFinalize(dest) else {
        removeFile(at: path)
        throw PigeonError(code: "encode", message: "CGImageDestinationFinalize failed", details: nil)
      }
      let size = byteSize(at: path)
      return [
        "outputPath": path,
        "sizeBytes": size,
        "format": format,
        "width": Int64(image.width),
        "height": Int64(image.height),
      ]
    default:
      throw PigeonError(code: "unsupported", message: "Unknown destination kind", details: nil)
    }
  }

  private static func makeSource(_ source: SourceMsg) throws -> CGImageSource {
    switch source.kind {
    case 0:
      guard let bytes = source.bytes else {
        throw PigeonError(code: "decode", message: "Empty image bytes", details: nil)
      }
      let data = bytes.data
      guard let cgSource = CGImageSourceCreateWithData(data as CFData, nil) else {
        throw PigeonError(code: "decode", message: "Unable to create image source", details: nil)
      }
      return cgSource
    case 1:
      guard let rawPath = source.path, !rawPath.isEmpty else {
        throw PigeonError(code: "notFound", message: "Missing source path", details: nil)
      }
      if rawPath.hasPrefix("content://") {
        throw PigeonError(
          code: "unsupported",
          message: "content:// is Android-only",
          details: nil)
      }
      let path = filesystemPath(rawPath)
      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw PigeonError(code: "notFound", message: "Image not found: \(path)", details: nil)
      }
      if isDirectory.boolValue {
        throw PigeonError(code: "io", message: "Image path is a directory: \(path)", details: nil)
      }
      let url = URL(fileURLWithPath: path)
      guard let cgSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw PigeonError(code: "decode", message: "Unable to create image source", details: nil)
      }
      return cgSource
    default:
      throw PigeonError(code: "unsupported", message: "Unknown source kind", details: nil)
    }
  }

  /// 用 ImageIO 缩略图 API 一步完成降采样解码与 EXIF 方向烘焙，
  /// 避免「全量解码 + CGContext 缩放」的高内存高耗时路径。
  ///
  /// Decodes via the ImageIO thumbnail API so downsampling and EXIF
  /// orientation baking happen in one pass, avoiding the expensive
  /// full-decode + CGContext rescale path.
  private static func decode(_ source: CGImageSource, maxDimension: Int?) throws -> CGImage {
    let requested = maxDimension.flatMap { $0 > 0 ? $0 : nil }
    let maxPixel = requested ?? longestEdge(of: source)
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    if let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions as CFDictionary)
    {
      return image
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw PigeonError(code: "decode", message: "CGImageSource returned no frame", details: nil)
    }
    return image
  }

  private static func longestEdge(of source: CGImageSource) -> Int {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      // Unknown size: a generous cap keeps the thumbnail API at full size.
      return 1 << 16
    }
    return max(width, height)
  }

  /// 拷贝源图元数据；方向已烘焙进像素，因此剔除 orientation 与过期尺寸字段。
  ///
  /// Copies source metadata; orientation is baked into pixels, so the
  /// orientation tag and stale dimension fields are stripped.
  private static func metadataProperties(from source: CGImageSource) -> [CFString: Any] {
    guard var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return [:]
    }
    props.removeValue(forKey: kCGImagePropertyOrientation)
    props.removeValue(forKey: kCGImagePropertyPixelWidth)
    props.removeValue(forKey: kCGImagePropertyPixelHeight)
    if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
      props[kCGImagePropertyTIFFDictionary] = tiff
    }
    if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
      exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
      exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
      props[kCGImagePropertyExifDictionary] = exif
    }
    return props
  }

  private static func destinationUTI(_ format: String) -> CFString? {
    switch format {
    case "jpeg": return "public.jpeg" as CFString
    case "png": return "public.png" as CFString
    case "heic": return "public.heic" as CFString
    case "webp": return "org.webmproject.webp" as CFString
    default: return nil
    }
  }

  private static func canDecode(_ uti: String) -> Bool {
    let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
    return identifiers.contains(uti)
  }

  private static func canEncode(_ uti: String) -> Bool {
    let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    return identifiers.contains(uti)
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
}

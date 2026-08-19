#if os(iOS)
  import Flutter
  import MobileCoreServices
#elseif os(macOS)
  import FlutterMacOS
  import CoreServices
#endif
import Foundation
import ImageIO

enum ImageCompressor {
  static func queryCapabilities() -> ImageCapabilitiesMsg {
    let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    var inputs = ["jpeg", "png", "gif", "heic"]
    if canDecode("org.webmproject.webp") { inputs.append("webp") }
    if canDecode("public.avif") { inputs.append("avif") }

    var outputs = ["jpeg", "png", "heic"]
    if identifiers.contains(where: { $0 == "org.webmproject.webp" }) {
      outputs.append("webp")
    }
    return ImageCapabilitiesMsg(inputFormats: inputs, outputFormats: outputs)
  }

  static func compress(
    source: SourceMsg,
    destination: DestinationMsg,
    options: ImageOptionsMsg
  ) throws -> [String: Any?] {
    let format = options.format
    guard let uti = destinationUTI(format) else {
      throw PigeonError(
        code: "unsupported",
        message: "Darwin cannot encode \(format)",
        details: nil)
    }
    if format == "gif" || format == "avif" {
      throw PigeonError(
        code: "unsupported", message: "Darwin cannot encode \(format)", details: nil)
    }

    let cgSource = try makeSource(source)
    guard let original = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else {
      throw PigeonError(code: "decode", message: "CGImageSource returned no frame", details: nil)
    }
    let image = scaleIfNeeded(original, maxDimension: options.maxDimension.map { Int($0) })
    let quality = Double(options.quality) / 100.0
    let destProperties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality
    ]

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
      guard let path = destination.path, !path.isEmpty else {
        throw PigeonError(code: "io", message: "Missing destination path", details: nil)
      }
      if path.hasPrefix("content://") {
        throw PigeonError(
          code: "unsupported",
          message: "content:// is Android-only",
          details: nil)
      }
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
        throw PigeonError(code: "encode", message: "CGImageDestinationCreateWithURL failed", details: nil)
      }
      CGImageDestinationAddImage(dest, image, destProperties as CFDictionary)
      guard CGImageDestinationFinalize(dest) else {
        throw PigeonError(code: "encode", message: "CGImageDestinationFinalize failed", details: nil)
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
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
      guard let path = source.path, !path.isEmpty else {
        throw PigeonError(code: "notFound", message: "Missing source path", details: nil)
      }
      if path.hasPrefix("content://") {
        throw PigeonError(
          code: "unsupported",
          message: "content:// is Android-only",
          details: nil)
      }
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw PigeonError(code: "notFound", message: "Image not found: \(path)", details: nil)
      }
      guard let cgSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw PigeonError(code: "decode", message: "Unable to create image source", details: nil)
      }
      return cgSource
    default:
      throw PigeonError(code: "unsupported", message: "Unknown source kind", details: nil)
    }
  }

  private static func scaleIfNeeded(_ image: CGImage, maxDimension: Int?) -> CGImage {
    guard let maxDimension, maxDimension > 0 else { return image }
    let longest = max(image.width, image.height)
    if longest <= maxDimension { return image }
    let scale = CGFloat(maxDimension) / CGFloat(longest)
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
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
}

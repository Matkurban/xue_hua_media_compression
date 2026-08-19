package com.xuehua.xue_hua_media_compression

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaCodecList
import android.os.Build
import android.util.Size
import androidx.heifwriter.HeifWriter
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

internal object ImageCompressor {
  fun queryCapabilities(): ImageCapabilitiesMsg {
    val inputs = mutableListOf("jpeg", "png", "webp", "gif")
    val outputs = mutableListOf("jpeg", "png", "webp")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      inputs.add("heic")
      outputs.add("heic")
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      inputs.add("avif")
    }
    return ImageCapabilitiesMsg(inputs, outputs)
  }

  fun compress(
      context: Context,
      source: SourceMsg,
      destination: DestinationMsg,
      options: ImageOptionsMsg,
  ): Map<String, Any?> {
    val format = options.format
    if (format == "gif" || format == "avif") {
      throw FlutterError("unsupported", "Android cannot encode $format", null)
    }
    if (format == "heic" && Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
      throw FlutterError("unsupported", "HEIC encode requires API 28+", null)
    }
    val bitmap = decode(context, source, options.maxDimension?.toInt())
    try {
      val quality = options.quality.toInt().coerceIn(1, 100)
      return when (destination.kind) {
        0L -> {
          val bytes = encodeToBytes(bitmap, format, quality)
          mapOf(
              "bytes" to bytes,
              "sizeBytes" to bytes.size.toLong(),
              "format" to format,
              "width" to bitmap.width.toLong(),
              "height" to bitmap.height.toLong(),
          )
        }
        1L -> {
          val path =
              destination.path
                  ?: throw FlutterError("io", "Missing destination path", null)
          writeFile(bitmap, format, quality, path)
          val size = File(path).length()
          mapOf(
              "outputPath" to path,
              "sizeBytes" to size,
              "format" to format,
              "width" to bitmap.width.toLong(),
              "height" to bitmap.height.toLong(),
          )
        }
        else -> throw FlutterError("unsupported", "Unknown destination kind", null)
      }
    } finally {
      bitmap.recycle()
    }
  }

  private fun decode(context: Context, source: SourceMsg, maxDimension: Int?): Bitmap {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      decodeModern(context, source, maxDimension)
    } else {
      decodeLegacy(context, source, maxDimension)
    }
  }

  private fun decodeModern(
      context: Context,
      source: SourceMsg,
      maxDimension: Int?,
  ): Bitmap {
    val decoderSource =
        when (source.kind) {
          0L -> {
            val bytes =
                source.bytes ?: throw FlutterError("decode", "Empty image bytes", null)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
              ImageDecoder.createSource(ByteBuffer.wrap(bytes))
            } else {
              val tmp = File.createTempFile("xh_img_", ".bin")
              tmp.writeBytes(bytes)
              tmp.deleteOnExit()
              ImageDecoder.createSource(tmp)
            }
          }
          1L -> {
            val path =
                source.path ?: throw FlutterError("notFound", "Missing source path", null)
            if (path.startsWith("content://")) {
              ImageDecoder.createSource(
                  context.contentResolver, android.net.Uri.parse(path))
            } else {
              val file = File(path)
              if (!file.exists()) {
                throw FlutterError("notFound", "Image not found: $path", null)
              }
              ImageDecoder.createSource(file)
            }
          }
          else -> throw FlutterError("unsupported", "Unknown source kind", null)
        }
    return try {
      ImageDecoder.decodeBitmap(decoderSource) { decoder, info, _ ->
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        if (maxDimension != null) {
          val size = scaledSize(info.size.width, info.size.height, maxDimension)
          decoder.setTargetSize(size.width, size.height)
        }
      }
    } catch (error: Exception) {
      throw FlutterError("decode", error.message ?: "Image decode failed", error.toString())
    }
  }

  private fun decodeLegacy(
      context: Context,
      source: SourceMsg,
      maxDimension: Int?,
  ): Bitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    when (source.kind) {
      0L -> {
        val bytes = source.bytes ?: throw FlutterError("decode", "Empty image bytes", null)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
      }
      1L -> {
        val path = source.path ?: throw FlutterError("notFound", "Missing source path", null)
        if (path.startsWith("content://")) {
          context.contentResolver.openInputStream(android.net.Uri.parse(path)).use {
            BitmapFactory.decodeStream(it, null, bounds)
          }
        } else {
          if (!File(path).exists()) {
            throw FlutterError("notFound", "Image not found: $path", null)
          }
          BitmapFactory.decodeFile(path, bounds)
        }
      }
      else -> throw FlutterError("unsupported", "Unknown source kind", null)
    }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      throw FlutterError("decode", "Unable to decode image bounds", null)
    }
    val sample =
        if (maxDimension == null) 1
        else {
          val longest = max(bounds.outWidth, bounds.outHeight)
          var s = 1
          while (longest / (s * 2) >= maxDimension) {
            s *= 2
          }
          s
        }
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    val bitmap =
        when (source.kind) {
          0L -> {
            val bytes = source.bytes!!
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
          }
          else -> {
            val path = source.path!!
            if (path.startsWith("content://")) {
              context.contentResolver.openInputStream(android.net.Uri.parse(path)).use {
                BitmapFactory.decodeStream(it, null, opts)
              }
            } else {
              BitmapFactory.decodeFile(path, opts)
            }
          }
        } ?: throw FlutterError("decode", "BitmapFactory returned null", null)
    return scaleIfNeeded(bitmap, maxDimension)
  }

  private fun scaleIfNeeded(bitmap: Bitmap, maxDimension: Int?): Bitmap {
    if (maxDimension == null) return bitmap
    val longest = max(bitmap.width, bitmap.height)
    if (longest <= maxDimension) return bitmap
    val size = scaledSize(bitmap.width, bitmap.height, maxDimension)
    val scaled = Bitmap.createScaledBitmap(bitmap, size.width, size.height, true)
    if (scaled !== bitmap) {
      bitmap.recycle()
    }
    return scaled
  }

  private fun scaledSize(width: Int, height: Int, maxDimension: Int): Size {
    val longest = max(width, height).toFloat()
    if (longest <= maxDimension) return Size(width, height)
    val scale = maxDimension / longest
    return Size(
        (width * scale).roundToInt().coerceAtLeast(1),
        (height * scale).roundToInt().coerceAtLeast(1),
    )
  }

  private fun encodeToBytes(bitmap: Bitmap, format: String, quality: Int): ByteArray {
    if (format == "heic") {
      val tmp = File.createTempFile("xh_heic_", ".heic")
      try {
        writeHeic(bitmap, quality, tmp.absolutePath)
        return tmp.readBytes()
      } finally {
        tmp.delete()
      }
    }
    val stream = ByteArrayOutputStream()
    if (!bitmap.compress(compressFormat(format), qualityFor(format, quality), stream)) {
      throw FlutterError("encode", "Bitmap.compress failed for $format", null)
    }
    return stream.toByteArray()
  }

  private fun writeFile(bitmap: Bitmap, format: String, quality: Int, path: String) {
    File(path).parentFile?.mkdirs()
    if (format == "heic") {
      writeHeic(bitmap, quality, path)
      return
    }
    FileOutputStream(File(path)).use { out ->
      if (!bitmap.compress(compressFormat(format), qualityFor(format, quality), out)) {
        throw FlutterError("encode", "Bitmap.compress failed for $format", null)
      }
    }
  }

  private fun writeHeic(bitmap: Bitmap, quality: Int, path: String) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
      throw FlutterError("unsupported", "HEIC encode requires API 28+", null)
    }
    File(path).parentFile?.mkdirs()
    val writer =
        HeifWriter.Builder(path, bitmap.width, bitmap.height, HeifWriter.INPUT_MODE_BITMAP)
            .setQuality(quality)
            .setMaxImages(1)
            .build()
    try {
      writer.start()
      writer.addBitmap(bitmap)
      writer.stop(0)
    } catch (error: Exception) {
      throw FlutterError("encode", error.message ?: "HeifWriter failed", error.toString())
    } finally {
      writer.close()
    }
  }

  private fun compressFormat(format: String): Bitmap.CompressFormat {
    return when (format) {
      "jpeg" -> Bitmap.CompressFormat.JPEG
      "png" -> Bitmap.CompressFormat.PNG
      "webp" ->
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Bitmap.CompressFormat.WEBP_LOSSY
          } else {
            @Suppress("DEPRECATION") Bitmap.CompressFormat.WEBP
          }
      else -> throw FlutterError("unsupported", "Unknown image format $format", null)
    }
  }

  private fun qualityFor(format: String, quality: Int): Int {
    return if (format == "png") 100 else quality
  }

  fun hasHardwareVideoEncoder(mime: String): Boolean {
    val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
    return list.codecInfos.any { info ->
      if (!info.isEncoder) return@any false
      if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) return@any false
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        info.isHardwareAccelerated
      } else {
        val name = info.name.lowercase()
        !name.startsWith("omx.google") && !name.startsWith("c2.android")
      }
    }
  }
}

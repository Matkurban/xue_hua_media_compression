package com.xuehua.xue_hua_media_compression

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.exifinterface.media.ExifInterface
import androidx.heifwriter.HeifWriter
import java.io.ByteArrayInputStream
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
      val keepMetadata = options.keepMetadata && metadataWritable(format)
      return when (destination.kind) {
        0L -> {
          var bytes = encodeToBytes(bitmap, format, quality)
          if (keepMetadata) {
            bytes = withMetadata(context, source, bytes, format)
          }
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
          if (keepMetadata) {
            try {
              copyMetadata(context, source, path)
            } catch (_: Exception) {
              // Metadata copy is best-effort; the compressed pixels stand.
            }
          }
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
    // BitmapFactory ignores EXIF orientation (unlike ImageDecoder on 28+),
    // so bake it here after downscaling to work on the smaller bitmap.
    return applyExifOrientation(context, source, scaleIfNeeded(bitmap, maxDimension))
  }

  private fun applyExifOrientation(
      context: Context,
      source: SourceMsg,
      bitmap: Bitmap,
  ): Bitmap {
    val orientation =
        try {
          openExif(context, source)
              ?.getAttributeInt(
                  ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) {
          null
        } ?: return bitmap
    val matrix = Matrix()
    when (orientation) {
      ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
      ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
      ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
      ExifInterface.ORIENTATION_TRANSPOSE -> {
        matrix.postRotate(90f)
        matrix.postScale(-1f, 1f)
      }
      ExifInterface.ORIENTATION_TRANSVERSE -> {
        matrix.postRotate(270f)
        matrix.postScale(-1f, 1f)
      }
      else -> return bitmap
    }
    val rotated =
        try {
          Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (_: OutOfMemoryError) {
          return bitmap
        }
    if (rotated !== bitmap) {
      bitmap.recycle()
    }
    return rotated
  }

  private fun openExif(context: Context, source: SourceMsg): ExifInterface? {
    return when (source.kind) {
      0L -> source.bytes?.let { ExifInterface(ByteArrayInputStream(it)) }
      1L -> {
        val path = source.path ?: return null
        if (path.startsWith("content://")) {
          context.contentResolver.openInputStream(Uri.parse(path))?.use { ExifInterface(it) }
        } else {
          ExifInterface(path)
        }
      }
      else -> null
    }
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

  // ExifInterface 仅支持对 JPEG/PNG/WebP 写元数据；HEIC 只读。
  private fun metadataWritable(format: String): Boolean {
    return format == "jpeg" || format == "png" || format == "webp"
  }

  private val exifTagsToCopy =
      arrayOf(
          ExifInterface.TAG_APERTURE_VALUE,
          ExifInterface.TAG_BRIGHTNESS_VALUE,
          ExifInterface.TAG_DATETIME,
          ExifInterface.TAG_DATETIME_DIGITIZED,
          ExifInterface.TAG_DATETIME_ORIGINAL,
          ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
          ExifInterface.TAG_EXPOSURE_TIME,
          ExifInterface.TAG_FLASH,
          ExifInterface.TAG_F_NUMBER,
          ExifInterface.TAG_FOCAL_LENGTH,
          ExifInterface.TAG_GPS_ALTITUDE,
          ExifInterface.TAG_GPS_ALTITUDE_REF,
          ExifInterface.TAG_GPS_DATESTAMP,
          ExifInterface.TAG_GPS_LATITUDE,
          ExifInterface.TAG_GPS_LATITUDE_REF,
          ExifInterface.TAG_GPS_LONGITUDE,
          ExifInterface.TAG_GPS_LONGITUDE_REF,
          ExifInterface.TAG_GPS_PROCESSING_METHOD,
          ExifInterface.TAG_GPS_TIMESTAMP,
          ExifInterface.TAG_IMAGE_DESCRIPTION,
          ExifInterface.TAG_LENS_MAKE,
          ExifInterface.TAG_LENS_MODEL,
          ExifInterface.TAG_MAKE,
          ExifInterface.TAG_METERING_MODE,
          ExifInterface.TAG_MODEL,
          ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
          ExifInterface.TAG_SCENE_TYPE,
          ExifInterface.TAG_SHUTTER_SPEED_VALUE,
          ExifInterface.TAG_SOFTWARE,
          ExifInterface.TAG_SUBJECT_DISTANCE,
          ExifInterface.TAG_USER_COMMENT,
          ExifInterface.TAG_WHITE_BALANCE,
      )

  // 将源图 EXIF 拷贝到已编码文件；方向已烘焙进像素，因此写回 NORMAL。
  //
  // Copies source EXIF onto the encoded file; orientation is baked into
  // the pixels, so NORMAL is written back.
  private fun copyMetadata(context: Context, source: SourceMsg, destPath: String) {
    val srcExif = openExif(context, source) ?: return
    val destExif = ExifInterface(destPath)
    for (tag in exifTagsToCopy) {
      srcExif.getAttribute(tag)?.let { destExif.setAttribute(tag, it) }
    }
    destExif.setAttribute(
        ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
    destExif.saveAttributes()
  }

  private fun withMetadata(
      context: Context,
      source: SourceMsg,
      encoded: ByteArray,
      format: String,
  ): ByteArray {
    val suffix =
        when (format) {
          "png" -> ".png"
          "webp" -> ".webp"
          else -> ".jpg"
        }
    val tmp = File.createTempFile("xh_meta_", suffix)
    return try {
      tmp.writeBytes(encoded)
      copyMetadata(context, source, tmp.absolutePath)
      tmp.readBytes()
    } catch (_: Exception) {
      encoded
    } finally {
      tmp.delete()
    }
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

package com.xuehua.xue_hua_media_compression

import android.content.Context
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

@UnstableApi
internal class VideoCompressor(
    private val context: Context,
    private val events: JobEventStream,
) {
  private val mainHandler = Handler(Looper.getMainLooper())
  private val cancelled = AtomicBoolean(false)
  @Volatile private var transformer: Transformer? = null
  private var progressRunnable: Runnable? = null

  fun start(inputPath: String, outputPath: String, options: VideoOptionsMsg) {
    val mime =
        when (options.codec) {
          "h265" -> MimeTypes.VIDEO_H265
          "h264" -> MimeTypes.VIDEO_H264
          else ->
              throw FlutterError("unsupported", "Unknown video codec ${options.codec}", null)
        }
    if (!ImageCompressor.hasHardwareVideoEncoder(mime)) {
      throw FlutterError(
          "hardwareUnavailable",
          "No hardware encoder for ${options.codec}",
          null,
      )
    }
    if (inputPath.startsWith("content://").not() && !File(inputPath).exists()) {
      throw FlutterError("notFound", "Video not found: $inputPath", null)
    }
    File(outputPath).parentFile?.mkdirs()

    val uri =
        if (inputPath.startsWith("content://") || inputPath.startsWith("file://")) {
          Uri.parse(inputPath)
        } else {
          Uri.fromFile(File(inputPath))
        }
    val sourceSize = probeSize(context, uri)
    val videoEffects = mutableListOf<androidx.media3.common.Effect>()
    val maxDimension = options.maxDimension?.toInt()
    var outWidth = sourceSize?.first ?: 0
    var outHeight = sourceSize?.second ?: 0
    if (maxDimension != null && sourceSize != null) {
      val longest = max(sourceSize.first, sourceSize.second)
      if (longest > maxDimension) {
        val scale = maxDimension.toFloat() / longest
        outWidth = (sourceSize.first * scale).roundToInt().coerceAtLeast(2) / 2 * 2
        outHeight = (sourceSize.second * scale).roundToInt().coerceAtLeast(2) / 2 * 2
        videoEffects.add(
            Presentation.createForWidthAndHeight(
                outWidth, outHeight, Presentation.LAYOUT_SCALE_TO_FIT))
      }
    }

    val edited =
        EditedMediaItem.Builder(MediaItem.fromUri(uri))
            .setRemoveAudio(!options.keepAudio)
            .apply {
              options.fps?.toInt()?.let { setFrameRate(it) }
              if (videoEffects.isNotEmpty()) {
                setEffects(Effects(/* audioProcessors= */ emptyList(), videoEffects))
              }
            }
            .build()

    val encoderSettings =
        VideoEncoderSettings.Builder()
            .setBitrate(options.bitrate.toInt().coerceAtLeast(1))
            .apply {
              val gopFrames = options.keyframeInterval?.toInt()
              if (gopFrames != null && gopFrames > 0) {
                // API 以帧为单位表达 GOP，Media3 需要秒：优先用请求的 fps 换算，
                // 未指定时按 30fps 估算。
                // The public API expresses GOP in frames while Media3 wants
                // seconds: convert using the requested fps, assuming 30 fps
                // when unspecified.
                val fps = options.fps?.toInt()?.takeIf { it > 0 } ?: 30
                setiFrameIntervalSeconds(gopFrames.toFloat() / fps)
              }
            }
            .build()

    val built =
        Transformer.Builder(context)
            .setVideoMimeType(mime)
            .setEncoderFactory(
                DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(encoderSettings)
                    .build())
            .addListener(
                object : Transformer.Listener {
                  override fun onCompleted(composition: Composition, result: ExportResult) {
                    stopProgress()
                    if (cancelled.get()) {
                      events.sendError("cancelled", "Cancelled", null)
                      return
                    }
                    val file = File(outputPath)
                    val size = if (file.exists()) file.length() else result.fileSizeBytes
                    val dims = probeSize(context, Uri.fromFile(file)) ?: (outWidth to outHeight)
                    events.sendCompleted(
                        mapOf(
                            "outputPath" to outputPath,
                            "sizeBytes" to size,
                            "encoderName" to "Media3Transformer",
                            "codec" to options.codec,
                            "width" to dims.first.toLong(),
                            "height" to dims.second.toLong(),
                        ))
                  }

                  override fun onError(
                      composition: Composition,
                      result: ExportResult,
                      exception: ExportException,
                  ) {
                    stopProgress()
                    if (cancelled.get()) {
                      events.sendError("cancelled", "Cancelled", null)
                      return
                    }
                    val code =
                        when (exception.errorCode) {
                          ExportException.ERROR_CODE_IO_FILE_NOT_FOUND -> "notFound"
                          ExportException.ERROR_CODE_DECODER_INIT_FAILED,
                          ExportException.ERROR_CODE_DECODING_FAILED -> "decode"
                          ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
                          ExportException.ERROR_CODE_ENCODING_FAILED -> "encode"
                          ExportException.ERROR_CODE_MUXING_FAILED -> "mux"
                          else -> "encode"
                        }
                    events.sendError(code, exception.message ?: "Transform failed", exception.toString())
                  }
                })
            .build()
    // Transformer 绑定 Looper（此处为主 Looper），start 必须回到该线程；
    // 前面的探测已在后台线程完成。
    // Transformer is bound to a Looper (main here), so start must run there;
    // all probing above already happened on a background thread.
    mainHandler.post {
      if (cancelled.get()) {
        events.sendError("cancelled", "Cancelled", null)
        return@post
      }
      transformer = built
      pollProgress(built)
      built.start(edited, outputPath)
    }
  }

  fun cancel() {
    cancelled.set(true)
    mainHandler.post {
      transformer?.cancel()
      stopProgress()
    }
  }

  private fun pollProgress(transformer: Transformer) {
    val runnable =
        object : Runnable {
          override fun run() {
            if (cancelled.get()) return
            val holder = ProgressHolder()
            val state = transformer.getProgress(holder)
            if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
              events.sendProgress(holder.progress / 100.0)
            }
            mainHandler.postDelayed(this, 120)
          }
        }
    progressRunnable = runnable
    mainHandler.postDelayed(runnable, 120)
  }

  private fun stopProgress() {
    progressRunnable?.let { mainHandler.removeCallbacks(it) }
    progressRunnable = null
  }

  companion object {
    fun probeSize(context: Context, uri: Uri): Pair<Int, Int>? {
      val retriever = MediaMetadataRetriever()
      return try {
        if (uri.scheme == "content") {
          retriever.setDataSource(context, uri)
        } else {
          retriever.setDataSource(uri.path)
        }
        val width =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt()
                ?: return null
        val height =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt()
                ?: return null
        width to height
      } catch (_: Exception) {
        null
      } finally {
        retriever.release()
      }
    }

    fun queryCapabilities(): VideoCapabilitiesMsg {
      val codecs = mutableListOf<String>()
      if (ImageCompressor.hasHardwareVideoEncoder(MediaFormat.MIMETYPE_VIDEO_AVC)) {
        codecs.add("h264")
      }
      if (ImageCompressor.hasHardwareVideoEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)) {
        codecs.add("h265")
      }
      val name = if (codecs.isEmpty()) null else "Media3Transformer"
      return VideoCapabilitiesMsg(name, codecs, acceptsContentUri = true)
    }
  }
}

package com.xuehua.xue_hua_media_compression

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.Executors

/**
 * Android implementation: ImageDecoder/Bitmap/HeifWriter + Media3 Transformer.
 *
 * Android 实现：图片走 ImageDecoder/Bitmap/HeifWriter，视频走 Media3 Transformer。
 */
class XueHuaMediaCompressionPlugin : FlutterPlugin, MediaCompressionHostApi {
  private lateinit var context: Context
  private lateinit var messenger: BinaryMessenger
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newCachedThreadPool()

  private val jobs = mutableMapOf<Long, Job>()
  private var nextId = 1L

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    messenger = binding.binaryMessenger
    MediaCompressionHostApi.setUp(messenger, this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    MediaCompressionHostApi.setUp(binding.binaryMessenger, null)
    jobs.values.forEach { it.dispose() }
    jobs.clear()
    executor.shutdownNow()
  }

  override fun createJob(): Long {
    val id = nextId++
    jobs[id] = Job(id, JobEventStream(messenger, id))
    return id
  }

  override fun queryImageCapabilities(): ImageCapabilitiesMsg {
    return ImageCompressor.queryCapabilities()
  }

  override fun startImageCompress(
      id: Long,
      source: SourceMsg,
      destination: DestinationMsg,
      options: ImageOptionsMsg,
      callback: (Result<Unit>) -> Unit,
  ) {
    val job =
        jobs[id]
            ?: return callback(
                Result.failure(FlutterError("instanceNotFound", "No job $id", null)))
    if (job.started) {
      return callback(
          Result.failure(FlutterError("invalidState", "Job $id already started", null)))
    }
    job.started = true
    callback(Result.success(Unit))
    executor.execute {
      try {
        if (job.cancelled) {
          job.events.sendError("cancelled", "Cancelled", null)
          return@execute
        }
        job.events.sendProgress(0.05)
        val result = ImageCompressor.compress(context, source, destination, options)
        if (job.cancelled) {
          job.events.sendError("cancelled", "Cancelled", null)
          return@execute
        }
        job.events.sendProgress(1.0)
        job.events.sendCompleted(result)
      } catch (error: FlutterError) {
        job.events.sendError(error.code, error.message ?: error.code, error.details?.toString())
      } catch (error: Exception) {
        job.events.sendError("encode", error.message ?: "Image compress failed", error.toString())
      }
    }
  }

  override fun queryVideoCapabilities(): VideoCapabilitiesMsg {
    return VideoCompressor.queryCapabilities()
  }

  @UnstableApi
  override fun startVideoCompress(
      id: Long,
      inputPath: String,
      outputPath: String,
      options: VideoOptionsMsg,
      callback: (Result<Unit>) -> Unit,
  ) {
    val job =
        jobs[id]
            ?: return callback(
                Result.failure(FlutterError("instanceNotFound", "No job $id", null)))
    if (job.started) {
      return callback(
          Result.failure(FlutterError("invalidState", "Job $id already started", null)))
    }
    job.started = true
    try {
      val compressor = VideoCompressor(context, job.events)
      job.video = compressor
      compressor.start(inputPath, outputPath, options)
      callback(Result.success(Unit))
    } catch (error: FlutterError) {
      callback(Result.failure(error))
    } catch (error: Exception) {
      callback(
          Result.failure(
              FlutterError("encode", error.message ?: "Video start failed", error.toString())))
    }
  }

  override fun cancelJob(id: Long) {
    val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
    job.cancelled = true
    job.video?.cancel()
  }

  override fun disposeJob(id: Long) {
    jobs.remove(id)?.dispose()
  }

  private class Job(val id: Long, val events: JobEventStream) {
    var started = false
    @Volatile var cancelled = false
    var video: VideoCompressor? = null

    fun dispose() {
      cancelled = true
      video?.cancel()
      events.dispose()
    }
  }
}

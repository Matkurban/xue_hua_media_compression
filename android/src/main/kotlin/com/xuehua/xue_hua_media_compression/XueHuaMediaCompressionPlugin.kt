package com.xuehua.xue_hua_media_compression

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.util.concurrent.Executors

/**
 * Android implementation: ImageDecoder/Bitmap/HeifWriter and MediaCodec/MediaMuxer.
 *
 * Jobs stay alive until the worker finishes so dispose during an encode does
 * not tear the event channel down from under the codec.
 */
class XueHuaMediaCompressionPlugin : FlutterPlugin, MediaCompressionHostApi {
    private lateinit var context: android.content.Context
    private lateinit var messenger: BinaryMessenger
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
        jobs.values.forEach { it.requestDispose() }
        jobs.clear()
        executor.shutdownNow()
    }

    override fun createJob(): Long {
        val id = nextId++
        jobs[id] = Job(JobEventStream(messenger, id))
        return id
    }

    override fun queryImageCapabilities(): ImageCapabilitiesMsg {
        return ImageCompressor.queryCapabilities()
    }

    override suspend fun startImageCompress(
        id: Long,
        source: SourceMsg,
        destination: DestinationMsg,
        options: ImageOptionsMsg,
    ) {
        val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
        if (job.started) {
            throw FlutterError("invalidState", "Job $id already started", null)
        }
        job.started = true
        val outputPath = if (destination.kind == 1L) destination.path else null
        executor.execute {
            try {
                if (job.cancelled) {
                    deleteIfPresent(outputPath)
                    job.events.sendError("cancelled", "Cancelled", null)
                    return@execute
                }
                job.events.sendProgress(0.05)
                val result =
                    ImageCompressor.compress(context, source, destination, options) {
                        job.cancelled
                    }
                if (job.cancelled) {
                    deleteIfPresent(outputPath)
                    job.events.sendError("cancelled", "Cancelled", null)
                    return@execute
                }
                job.events.sendProgress(1.0)
                job.events.sendCompleted(result)
            } catch (error: FlutterError) {
                if (error.code == "cancelled" || job.cancelled) {
                    deleteIfPresent(outputPath)
                    job.events.sendError("cancelled", "Cancelled", null)
                } else {
                    job.events.sendError(
                        error.code,
                        error.message ?: error.code,
                        error.details?.toString(),
                    )
                }
            } catch (error: Exception) {
                deleteIfPresent(outputPath)
                job.events.sendError(
                    "encode",
                    error.message ?: "Image compress failed",
                    error.toString(),
                )
            } finally {
                job.onWorkerFinished()
            }
        }
    }

    override fun queryVideoCapabilities(): VideoCapabilitiesMsg {
        return VideoCompressor.queryCapabilities()
    }

    override suspend fun startVideoCompress(
        id: Long,
        inputPath: String,
        outputPath: String,
        options: VideoOptionsMsg,
    ) {
        val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
        if (job.started) {
            throw FlutterError("invalidState", "Job $id already started", null)
        }
        job.started = true
        executor.execute {
            try {
                if (job.cancelled) {
                    deleteIfPresent(outputPath)
                    job.events.sendError("cancelled", "Cancelled", null)
                    return@execute
                }
                val compressor =
                    VideoCompressor(context, job.events) {
                        job.cancelled
                    }
                val result = compressor.start(inputPath, outputPath, options)
                if (job.cancelled) {
                    deleteIfPresent(outputPath)
                    job.events.sendError("cancelled", "Cancelled", null)
                    return@execute
                }
                job.events.sendProgress(1.0)
                job.events.sendCompleted(result)
            } catch (error: FlutterError) {
                deleteIfPresent(outputPath)
                val code = if (job.cancelled) "cancelled" else error.code
                job.events.sendError(
                    code,
                    if (code == "cancelled") "Cancelled" else error.message ?: error.code,
                    error.details?.toString(),
                )
            } catch (error: Exception) {
                deleteIfPresent(outputPath)
                job.events.sendError(
                    if (job.cancelled) "cancelled" else "encode",
                    error.message ?: "Video compress failed",
                    error.toString(),
                )
            } finally {
                job.onWorkerFinished()
            }
        }
    }

    override fun cancelJob(id: Long) {
        val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
        job.cancelled = true
    }

    override fun disposeJob(id: Long) {
        jobs.remove(id)?.requestDispose()
    }

    private fun deleteIfPresent(path: String?) {
        if (path.isNullOrEmpty() || path.startsWith("content://")) return
        try {
            File(path).delete()
        } catch (_: Exception) {
        }
    }

    private class Job(val events: JobEventStream) {
        var started = false

        @Volatile
        var cancelled = false

        private val gate = Any()
        private var workerFinished = false
        private var disposeRequested = false

        fun onWorkerFinished() {
            val disposeNow =
                synchronized(gate) {
                    workerFinished = true
                    disposeRequested
                }
            if (disposeNow) {
                events.dispose()
            }
        }

        fun requestDispose() {
            cancelled = true
            val disposeNow =
                synchronized(gate) {
                    disposeRequested = true
                    workerFinished
                }
            if (disposeNow) {
                events.dispose()
            }
        }
    }
}

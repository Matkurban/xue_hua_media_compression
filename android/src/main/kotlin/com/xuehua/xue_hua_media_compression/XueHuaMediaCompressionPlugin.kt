package com.xuehua.xue_hua_media_compression

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext

/**
 * Android implementation: ImageDecoder/Bitmap/HeifWriter and MediaCodec/MediaMuxer
 * exposed through Pigeon Native Interop (JNI).
 *
 * Jobs keep their relay alive until worker completion and Dart disposal agree
 * so cancelling or disposing mid-flight never tears down callbacks too early.
 */
class XueHuaMediaCompressionPlugin : FlutterPlugin, MediaCompressionHostApi {
    private lateinit var context: Context
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private val hostRegistrar = MediaCompressionHostApiRegistrar()
    private val flutterApiRegistrar = MediaCompressionFlutterApiRegistrar()
    private val executor = Executors.newCachedThreadPool()
    private val relayScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val jobs = ConcurrentHashMap<Long, Job>()
    private val nextId = AtomicLong(1L)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        pluginBinding = binding
        hostRegistrar.register(this, binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        hostRegistrar.unregister(this, binding)
        pluginBinding = null
        jobs.values.forEach { it.requestDispose() }
        jobs.clear()
        relayScope.cancel()
        executor.shutdownNow()
    }

    override fun createJob(): Long {
        val id = nextId.getAndIncrement()
        jobs[id] = Job()
        return id
    }

    override suspend fun queryImageCapabilities(): ImageCapabilitiesMsg =
        withContext(Dispatchers.IO) {
            ImageCompressor.queryCapabilities()
        }

    override suspend fun startImageCompress(
        id: Long,
        source: SourceMsg,
        destination: DestinationMsg,
        options: ImageOptionsMsg,
    ) {
        val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
        val binding = pluginBinding ?: throw FlutterError("invalidState", "Plugin not attached", null)
        val flutterApi = flutterApiRegistrar.getInstance(binding, "job_$id")
        val relay = JobFlutterEventRelay(flutterApi, relayScope)
        if (!job.begin(relay)) {
            throw FlutterError("invalidState", "Job $id already started", null)
        }
        val outputPath = if (destination.kind == 1L) destination.path else null
        try {
            executor.execute {
                try {
                    if (job.cancelled) {
                        deleteIfPresent(outputPath)
                        relay.sendError("cancelled", "Cancelled")
                        return@execute
                    }
                    relay.sendProgress(0.05)
                    val result =
                        ImageCompressor.compress(
                            context = context,
                            source = source,
                            destination = destination,
                            options = options,
                            onProgress = { value -> relay.sendProgress(value) },
                        ) {
                            job.cancelled
                        }
                    if (job.cancelled) {
                        deleteIfPresent(outputPath)
                        relay.sendError("cancelled", "Cancelled")
                        return@execute
                    }
                    relay.sendProgress(1.0)
                    relay.sendImageCompleted(result)
                } catch (error: FlutterError) {
                    if (error.code == "cancelled" || job.cancelled) {
                        deleteIfPresent(outputPath)
                        relay.sendError("cancelled", "Cancelled")
                    } else {
                        relay.sendError(error.code, error.message ?: error.code)
                    }
                } catch (error: Exception) {
                    deleteIfPresent(outputPath)
                    relay.sendError(
                        if (job.cancelled) "cancelled" else "encode",
                        error.message ?: "Image compress failed",
                    )
                } finally {
                    job.onWorkerFinished()
                }
            }
        } catch (_: RejectedExecutionException) {
            job.onWorkerFinished()
            throw FlutterError("cancelled", "Plugin detached", null)
        }
    }

    override suspend fun queryVideoCapabilities(): VideoCapabilitiesMsg =
        withContext(Dispatchers.IO) {
            VideoCompressor.queryCapabilities()
        }

    override suspend fun startVideoCompress(
        id: Long,
        inputPath: String,
        outputPath: String,
        options: VideoOptionsMsg,
    ) {
        val job = jobs[id] ?: throw FlutterError("instanceNotFound", "No job $id", null)
        val binding = pluginBinding ?: throw FlutterError("invalidState", "Plugin not attached", null)
        val flutterApi = flutterApiRegistrar.getInstance(binding, "job_$id")
        val relay = JobFlutterEventRelay(flutterApi, relayScope)
        if (!job.begin(relay)) {
            throw FlutterError("invalidState", "Job $id already started", null)
        }
        try {
            executor.execute {
                try {
                    if (job.cancelled) {
                        deleteIfPresent(outputPath)
                        relay.sendError("cancelled", "Cancelled")
                        return@execute
                    }
                    val compressor =
                        VideoCompressor(context, relay) {
                            job.cancelled
                        }
                    val result = compressor.start(inputPath, outputPath, options)
                    if (job.cancelled) {
                        deleteIfPresent(outputPath)
                        relay.sendError("cancelled", "Cancelled")
                        return@execute
                    }
                    relay.sendProgress(1.0)
                    relay.sendVideoCompleted(result)
                } catch (error: FlutterError) {
                    deleteIfPresent(outputPath)
                    val code = if (job.cancelled) "cancelled" else error.code
                    relay.sendError(
                        code,
                        if (code == "cancelled") "Cancelled" else error.message ?: error.code,
                    )
                } catch (error: Exception) {
                    deleteIfPresent(outputPath)
                    relay.sendError(
                        if (job.cancelled) "cancelled" else "encode",
                        error.message ?: "Video compress failed",
                    )
                } finally {
                    job.onWorkerFinished()
                }
            }
        } catch (_: RejectedExecutionException) {
            job.onWorkerFinished()
            throw FlutterError("cancelled", "Plugin detached", null)
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

    private class Job {
        @Volatile
        var cancelled = false

        private val gate = Any()
        private var started = false
        private var workerFinished = false
        private var disposeRequested = false
        private var relay: JobFlutterEventRelay? = null

        fun begin(eventRelay: JobFlutterEventRelay): Boolean {
            synchronized(gate) {
                if (started || disposeRequested) {
                    return false
                }
                started = true
                relay = eventRelay
                return true
            }
        }

        fun onWorkerFinished() {
            val relayToDispose =
                synchronized(gate) {
                    workerFinished = true
                    if (disposeRequested) relay else null
                }
            relayToDispose?.dispose()
        }

        fun requestDispose() {
            cancelled = true
            val relayToDispose =
                synchronized(gate) {
                    disposeRequested = true
                    if (!started || workerFinished) relay else null
                }
            relayToDispose?.dispose()
        }
    }
}

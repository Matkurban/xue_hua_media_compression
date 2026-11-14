package com.xuehua.xue_hua_media_compression

import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Relays per-job progress, completion, and errors over Pigeon's `@FlutterApi`
 * in strict FIFO order while throttling intermediate progress updates to >= 100 ms.
 */
internal class JobFlutterEventRelay(
    private val flutterApi: MediaCompressionFlutterApi?,
    private val scope: CoroutineScope,
) {
    private sealed interface PendingEvent {
        data class Progress(val value: Double) : PendingEvent
        data class ImageCompleted(val result: ImageCompressResultMsg) : PendingEvent
        data class VideoCompleted(val result: VideoCompressResultMsg) : PendingEvent
        data class Error(val code: String, val message: String) : PendingEvent
    }

    private val lock = Any()
    private val queue = ArrayDeque<PendingEvent>()
    private var terminal = false
    private var disposed = false
    private var draining = false
    private var sentPositive = false
    private var lastProgressSentAt = 0L
    private var lastProgress: Double? = null

    fun sendProgress(value: Double) {
        val clamped = value.coerceIn(0.0, 1.0)
        synchronized(lock) {
            if (disposed || terminal) return
            lastProgress = clamped
            val now = SystemClock.elapsedRealtime()
            val firstPositive = clamped > 0.0 && clamped < 1.0 && !sentPositive
            if (!firstPositive && clamped < 1.0 && (now - lastProgressSentAt) < 100L) {
                return
            }
            if (firstPositive) {
                sentPositive = true
            }
            lastProgressSentAt = now
            if (queue.lastOrNull() is PendingEvent.Progress) {
                queue.removeLast()
            }
            queue.addLast(PendingEvent.Progress(clamped))
            scheduleDrainLocked()
        }
    }

    fun sendImageCompleted(result: ImageCompressResultMsg) {
        synchronized(lock) {
            if (disposed || terminal) return
            terminal = true
            val pending = lastProgress
            if (pending != null && pending < 1.0) {
                queue.addLast(PendingEvent.Progress(1.0))
            }
            queue.addLast(PendingEvent.ImageCompleted(result))
            scheduleDrainLocked()
        }
    }

    fun sendVideoCompleted(result: VideoCompressResultMsg) {
        synchronized(lock) {
            if (disposed || terminal) return
            terminal = true
            val pending = lastProgress
            if (pending != null && pending < 1.0) {
                queue.addLast(PendingEvent.Progress(1.0))
            }
            queue.addLast(PendingEvent.VideoCompleted(result))
            scheduleDrainLocked()
        }
    }

    fun sendError(code: String, message: String) {
        synchronized(lock) {
            if (disposed || terminal) return
            terminal = true
            queue.addLast(PendingEvent.Error(code, message))
            scheduleDrainLocked()
        }
    }

    fun dispose() {
        synchronized(lock) {
            disposed = true
            terminal = true
            queue.clear()
        }
    }

    private fun scheduleDrainLocked() {
        if (draining || queue.isEmpty()) return
        val api = flutterApi
        if (api == null) {
            queue.clear()
            return
        }
        draining = true
        scope.launch {
            drainLoop(api)
        }
    }

    private suspend fun drainLoop(api: MediaCompressionFlutterApi) {
        while (true) {
            val next =
                synchronized(lock) {
                    if (disposed || queue.isEmpty()) {
                        queue.clear()
                        draining = false
                        return
                    }
                    queue.removeFirst()
                }
            try {
                when (next) {
                    is PendingEvent.Progress -> api.onProgress(next.value)
                    is PendingEvent.ImageCompleted -> api.onImageCompleted(next.result)
                    is PendingEvent.VideoCompleted -> api.onVideoCompleted(next.result)
                    is PendingEvent.Error -> api.onError(next.code, next.message)
                }
            } catch (error: CancellationException) {
                synchronized(lock) {
                    draining = false
                }
                throw error
            } catch (_: Exception) {
                // Ignore delivery errors after Dart tears down the job callback.
            }
        }
    }
}

package com.xuehua.xue_hua_media_compression

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Per-job EventChannel with the buffering rules required by the Dart session:
 * progress is coalesced to the latest value until listen; completed/error are
 * never dropped; progress is throttled to ≥100ms.
 *
 * 每个会话一条 EventChannel：listen 前进度只保留最新一条；终态必须入队；
 * 进度节流不少于 100ms。
 */
internal class JobEventStream(messenger: BinaryMessenger, id: Long) :
    EventChannel.StreamHandler {

    private val channel =
        EventChannel(messenger, "xue_hua_media_compression/job_events_$id")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private var sink: EventChannel.EventSink? = null
    private var lastProgress: Double? = null
    private val pendingTerminal = ArrayDeque<Map<String, Any?>>()
    private var lastProgressSentAt = 0L
    private var terminalSent = false

    init {
        channel.setStreamHandler(this)
    }

    fun sendProgress(value: Double) {
        runOnMain {
            if (closed.get() || terminalSent) return@runOnMain
            val clamped = value.coerceIn(0.0, 1.0)
            val now = SystemClock.elapsedRealtime()
            val currentSink = sink
            if (currentSink == null) {
                lastProgress = clamped
                return@runOnMain
            }
            if (clamped < 1.0 && now - lastProgressSentAt < 100) {
                lastProgress = clamped
                return@runOnMain
            }
            lastProgressSentAt = now
            lastProgress = null
            currentSink.success(mapOf("type" to "progress", "value" to clamped))
        }
    }

    fun sendCompleted(result: Map<String, Any?>) {
        runOnMain {
            if (closed.get() || terminalSent) return@runOnMain
            terminalSent = true
            flushPendingProgress()
            deliver(mapOf("type" to "completed", "result" to result))
        }
    }

    fun sendError(code: String, message: String, details: String? = null) {
        runOnMain {
            if (closed.get() || terminalSent) return@runOnMain
            terminalSent = true
            deliver(
                mapOf(
                    "type" to "error",
                    "code" to code,
                    "message" to message,
                    "details" to details,
                ),
            )
        }
    }

    fun dispose() {
        runOnMain {
            closed.set(true)
            sink = null
            channel.setStreamHandler(null)
            pendingTerminal.clear()
            lastProgress = null
        }
    }

    private fun flushPendingProgress() {
        val pending = lastProgress ?: return
        val currentSink = sink ?: return
        lastProgress = null
        lastProgressSentAt = SystemClock.elapsedRealtime()
        currentSink.success(mapOf("type" to "progress", "value" to pending))
    }

    private fun deliver(event: Map<String, Any?>) {
        val currentSink = sink
        if (currentSink != null) {
            currentSink.success(event)
        } else if (!closed.get()) {
            pendingTerminal.addLast(event)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        lastProgress?.let { events.success(mapOf("type" to "progress", "value" to it)) }
        lastProgress = null
        while (pendingTerminal.isNotEmpty()) {
            events.success(pendingTerminal.removeFirst())
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }
}

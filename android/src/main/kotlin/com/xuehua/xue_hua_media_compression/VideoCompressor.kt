package com.xuehua.xue_hua_media_compression

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Bundle
import androidx.core.net.toUri
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.nio.ByteBuffer
import kotlin.math.max

/**
 * Video compress on MediaCodec + MediaMuxer.
 *
 * Hardware encoders are tried first. If none exist, or the hardware encoder
 * rejects the frame, a software encoder is used. There is no FFmpeg.
 */
internal class VideoCompressor(
    private val context: Context,
    private val events: JobEventStream,
    private val isCancelled: () -> Boolean,
) {
    fun start(inputPath: String, outputPath: String, options: VideoOptionsMsg): Map<String, Any?> {
        val mime =
            when (options.codec) {
                "h265" -> MediaFormat.MIMETYPE_VIDEO_HEVC
                "h264" -> MediaFormat.MIMETYPE_VIDEO_AVC
                else ->
                    throw FlutterError(
                        "unsupported",
                        "Unknown video codec ${options.codec}",
                        null,
                    )
            }
        if (!MediaCodecs.hasEncoder(mime)) {
            throw FlutterError("unsupported", "No ${options.codec} encoder installed", null)
        }
        val resolvedInput = normalizePath(inputPath)
        val resolvedOutput = normalizePath(outputPath)
        val parent = File(resolvedOutput).parentFile
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw FlutterError("io", "Cannot create ${parent.path}", null)
        }
        throwIfCancelled()
        events.sendProgress(0.01)
        var success = false
        try {
            val result = transcode(resolvedInput, resolvedOutput, options, mime)
            success = true
            return result
        } finally {
            if (!success) {
                File(resolvedOutput).delete()
            }
        }
    }

    private fun transcode(
        inputPath: String,
        outputPath: String,
        options: VideoOptionsMsg,
        mime: String,
    ): Map<String, Any?> {
        val extractor = openExtractor(inputPath)
        var decoder: MediaCodec? = null
        var encoder: OpenEncoder? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        try {
            val videoIndex = videoTrack(extractor)
            extractor.selectTrack(videoIndex)
            val inputFormat = extractor.getTrackFormat(videoIndex)
            val inputMime =
                inputFormat.getString(MediaFormat.KEY_MIME)
                    ?: throw FlutterError("decode", "Video track has no mime", null)
            val videoDecoder =
                try {
                    MediaCodec.createDecoderByType(inputMime)
                } catch (error: Exception) {
                    throw FlutterError(
                        "decode",
                        "No decoder for $inputMime",
                        error.toString(),
                    )
                }
            decoder = videoDecoder
            videoDecoder.configure(inputFormat, null, null, 0)
            videoDecoder.start()

            val sourceFps = positiveInt(inputFormat, MediaFormat.KEY_FRAME_RATE, 30)
            val requestedFps = options.fps?.toInt()?.takeIf { it > 0 }
            val outputFps =
                if (requestedFps == null || requestedFps >= sourceFps) sourceFps else requestedFps
            val dropStep =
                if (requestedFps == null || requestedFps >= sourceFps) {
                    1.0
                } else {
                    sourceFps.toDouble() / requestedFps.toDouble()
                }
            val durationUs = positiveLong(inputFormat, MediaFormat.KEY_DURATION, 0L)
            val keyframeInterval = options.keyframeInterval?.toInt()?.takeIf { it > 0 }
            val iFrameSeconds =
                if (keyframeInterval == null) {
                    1f
                } else {
                    keyframeInterval.toFloat() / outputFps.toFloat()
                }
            val bitrate = options.bitrate.toInt().coerceAtLeast(1)
            val rotation = positiveInt(inputFormat, "rotation-degrees", 0)

            val samples = ArrayList<Sample>()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var decoderFormat: MediaFormat? = null
            var frameIndex = 0
            var emitted = 0
            var nextKeep = 0.0
            var trackWidth = positiveInt(inputFormat, MediaFormat.KEY_WIDTH, 0)
            var trackHeight = positiveInt(inputFormat, MediaFormat.KEY_HEIGHT, 0)
            val decodeDeadline = android.os.SystemClock.elapsedRealtime() + 180_000L

            while (true) {
                throwIfCancelled()
                if (android.os.SystemClock.elapsedRealtime() > decodeDeadline) {
                    throw FlutterError("encode", "Decoder timed out", null)
                }
                if (!inputDone) {
                    val inIndex = videoDecoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer =
                            videoDecoder.getInputBuffer(inIndex)
                                ?: throw FlutterError("decode", "Decoder input buffer missing", null)
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            videoDecoder.queueInputBuffer(
                                inIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            val pts = extractor.sampleTime.coerceAtLeast(0L)
                            videoDecoder.queueInputBuffer(inIndex, 0, size, pts, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = videoDecoder.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        decoderFormat = videoDecoder.outputFormat
                    }

                    outIndex >= 0 -> {
                        val eos = flag(info.flags, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        if (info.size > 0 && !eos) {
                            if (frameIndex.toDouble() + 0.01 >= nextKeep) {
                                nextKeep += dropStep
                                val visible =
                                    visibleSourceSize(videoDecoder, outIndex, trackWidth, trackHeight)
                                trackWidth = visible.first
                                trackHeight = visible.second
                                val target =
                                    MediaCodecs.outputSize(
                                        trackWidth,
                                        trackHeight,
                                        options.maxDimension?.toInt(),
                                    )
                                if (encoder == null) {
                                    encoder =
                                        openEncoder(
                                            mime,
                                            target.first,
                                            target.second,
                                            outputFps,
                                            bitrate,
                                            iFrameSeconds,
                                        )
                                }
                                val opened = encoder!!
                                if (keyframeInterval != null &&
                                    emitted > 0 &&
                                    emitted % keyframeInterval == 0
                                ) {
                                    val bundle = Bundle()
                                    bundle.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                                    opened.codec.setParameters(bundle)
                                }
                                val i420 =
                                    readDecodedFrame(
                                        videoDecoder,
                                        outIndex,
                                        info,
                                        decoderFormat,
                                        visible,
                                    )
                                queueVideoFrame(
                                    opened,
                                    i420,
                                    visible,
                                    opened.width to opened.height,
                                    emitted * 1_000_000L / outputFps,
                                    samples,
                                )
                                drainVideoEncoder(opened, samples, untilEos = false)
                                emitted += 1
                                val fraction =
                                    if (durationUs > 0L) {
                                        info.presentationTimeUs.toDouble() / durationUs.toDouble()
                                    } else {
                                        emitted.toDouble() / (emitted + 8).toDouble()
                                    }
                                events.sendProgress(fraction.coerceIn(0.0, 0.99))
                            }
                            frameIndex += 1
                        }
                        videoDecoder.releaseOutputBuffer(outIndex, false)
                        if (eos) break
                    }
                }
            }
            val runningEncoder =
                encoder ?: throw FlutterError("decode", "No video frames decoded", null)
            if (emitted == 0) {
                throw FlutterError("decode", "No video frames decoded", null)
            }
            signalVideoEos(runningEncoder, samples)
            drainVideoEncoder(runningEncoder, samples, untilEos = true)
            if (samples.isEmpty()) {
                throw FlutterError("encode", "Encoder produced no samples", null)
            }
            val encoderFormat =
                runningEncoder.format
                    ?: throw FlutterError("encode", "Encoder produced no output format", null)
            encoderFormat.setInteger(MediaFormat.KEY_WIDTH, runningEncoder.width)
            encoderFormat.setInteger(MediaFormat.KEY_HEIGHT, runningEncoder.height)
            encoderFormat.setInteger("crop-left", 0)
            encoderFormat.setInteger("crop-top", 0)
            encoderFormat.setInteger("crop-right", runningEncoder.width - 1)
            encoderFormat.setInteger("crop-bottom", runningEncoder.height - 1)

            val audio =
                if (options.keepAudio) {
                    loadAudio(inputPath)
                } else {
                    null
                }
            throwIfCancelled()

            try {
                val container = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = container
                if (rotation == 90 || rotation == 180 || rotation == 270) {
                    container.setOrientationHint(rotation)
                }
                val videoTrackIndex = container.addTrack(encoderFormat)
                val audioTrackIndex =
                    if (audio != null && audio.samples.isNotEmpty()) {
                        container.addTrack(audio.format)
                    } else {
                        -1
                    }
                container.start()
                muxerStarted = true
                writeSamples(container, videoTrackIndex, samples)
                if (audioTrackIndex >= 0 && audio != null) {
                    writeSamples(container, audioTrackIndex, audio.samples)
                }
                container.stop()
                muxerStarted = false
                container.release()
                muxer = null
            } catch (error: FlutterError) {
                throw error
            } catch (error: Exception) {
                throw FlutterError("mux", error.message ?: "Mux failed", error.toString())
            }

            throwIfCancelled()
            val file = File(outputPath)
            val label = if (options.codec == "h265") "H265" else "H264"
            val encoderName =
                if (runningEncoder.hardware) {
                    "MediaCodecHW:$label"
                } else {
                    "MediaCodec:$label"
                }
            return mapOf(
                "outputPath" to outputPath,
                "sizeBytes" to file.length(),
                "encoderName" to encoderName,
                "codec" to options.codec,
                "width" to runningEncoder.width.toLong(),
                "height" to runningEncoder.height.toLong(),
            )
        } catch (error: FlutterError) {
            throw error
        } catch (error: Exception) {
            throw FlutterError("encode", error.message ?: "Video compress failed", error.toString())
        } finally {
            releaseCodec(decoder)
            releaseCodec(encoder?.codec)
            if (muxer != null) {
                try {
                    if (muxerStarted) muxer.stop()
                } catch (_: Exception) {
                }
                try {
                    muxer.release()
                } catch (_: Exception) {
                }
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun visibleSourceSize(
        decoder: MediaCodec,
        index: Int,
        trackWidth: Int,
        trackHeight: Int,
    ): Pair<Int, Int> {
        val image =
            try {
                decoder.getOutputImage(index)
            } catch (_: Exception) {
                null
            }
        try {
            val cropW = image?.cropRect?.width() ?: 0
            val cropH = image?.cropRect?.height() ?: 0
            val width =
                when {
                    trackWidth > 0 && (cropW <= 0 || trackWidth <= cropW) -> trackWidth
                    cropW > 0 -> cropW
                    else -> trackWidth
                }
            val height =
                when {
                    trackHeight > 0 && (cropH <= 0 || trackHeight <= cropH) -> trackHeight
                    cropH > 0 -> cropH
                    else -> trackHeight
                }
            if (width <= 0 || height <= 0) {
                throw FlutterError("decode", "Video frame has no size", null)
            }
            return width to height
        } finally {
            image?.close()
        }
    }

    private fun readDecodedFrame(
        decoder: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
        decoderFormat: MediaFormat?,
        visible: Pair<Int, Int>,
    ): ByteArray {
        val out = Yuv.allocate(visible.first, visible.second)
        val image =
            try {
                decoder.getOutputImage(index)
            } catch (_: Exception) {
                null
            }
        try {
            if (image != null && image.planes.size >= 3) {
                Yuv.readImage(image, visible.first, visible.second, out)
            } else {
                val buffer =
                    decoder.getOutputBuffer(index)
                        ?: throw FlutterError("decode", "Decoder output buffer missing", null)
                val format = decoderFormat ?: decoder.outputFormat
                Yuv.readCodecBuffer(buffer, info.offset, format, visible.first, visible.second, out)
            }
        } finally {
            image?.close()
        }
        return out
    }

    private fun queueVideoFrame(
        encoder: OpenEncoder,
        i420: ByteArray,
        source: Pair<Int, Int>,
        target: Pair<Int, Int>,
        pts: Long,
        samples: MutableList<Sample>,
    ) {
        var spins = 0
        while (spins < 200) {
            throwIfCancelled()
            val index = encoder.codec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) {
                drainVideoEncoder(encoder, samples, untilEos = false)
                spins += 1
                continue
            }
            val buffer =
                encoder.codec.getInputBuffer(index)
                    ?: throw FlutterError("encode", "Encoder input buffer missing", null)
            val image =
                try {
                    encoder.codec.getInputImage(index)
                } catch (_: Exception) {
                    null
                }
            val planarImage = image != null && image.planes.size >= 3
            val size =
                try {
                    if (image != null && planarImage) {
                        Yuv.writeImage(i420, source.first, source.second, image, target.first, target.second)
                        buffer.capacity()
                    } else {
                        Yuv.writeBuffer(
                            i420,
                            source.first,
                            source.second,
                            buffer,
                            target.first,
                            target.second,
                            encoder.colorFormat,
                        )
                        target.first * target.second * 3 / 2
                    }
                } finally {
                    image?.close()
                }
            encoder.codec.queueInputBuffer(index, 0, size, pts.coerceAtLeast(0L), 0)
            return
        }
        throw FlutterError("encode", "Encoder did not accept a frame", null)
    }

    private fun signalVideoEos(encoder: OpenEncoder, samples: MutableList<Sample>) {
        var spins = 0
        while (spins < 200) {
            throwIfCancelled()
            val index = encoder.codec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) {
                drainVideoEncoder(encoder, samples, untilEos = false)
                spins += 1
                continue
            }
            encoder.codec.queueInputBuffer(
                index,
                0,
                0,
                0,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
            )
            return
        }
        throw FlutterError("encode", "Encoder did not accept end of stream", null)
    }

    private fun drainVideoEncoder(encoder: OpenEncoder, samples: MutableList<Sample>, untilEos: Boolean) {
        val info = MediaCodec.BufferInfo()
        val deadline = android.os.SystemClock.elapsedRealtime() + if (untilEos) 20_000L else 0L
        while (true) {
            throwIfCancelled()
            val index =
                encoder.codec.dequeueOutputBuffer(
                    info,
                    if (untilEos) TIMEOUT_US else 0L,
                )
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEos) return
                    if (android.os.SystemClock.elapsedRealtime() > deadline) {
                        throw FlutterError("encode", "Encoder timed out", null)
                    }
                }

                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (encoder.format == null) {
                        encoder.format = encoder.codec.outputFormat
                    }
                }

                index >= 0 -> {
                    val eos = flag(info.flags, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    val config = flag(info.flags, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
                    if (info.size > 0 && !config) {
                        val buffer = encoder.codec.getOutputBuffer(index)
                        if (buffer != null) {
                            val data = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(data)
                            val flags =
                                if (flag(info.flags, MediaCodec.BUFFER_FLAG_SYNC_FRAME)) {
                                    MediaCodec.BUFFER_FLAG_SYNC_FRAME
                                } else {
                                    0
                                }
                            samples.add(Sample(data, info.presentationTimeUs.coerceAtLeast(0L), flags))
                        }
                    }
                    encoder.codec.releaseOutputBuffer(index, false)
                    if (eos) return
                }

                else -> {
                    if (!untilEos || android.os.SystemClock.elapsedRealtime() > deadline) {
                        if (untilEos) {
                            throw FlutterError("encode", "Encoder timed out", null)
                        }
                        return
                    }
                }
            }
        }
    }

    private fun loadAudio(inputPath: String): AudioTrack? {
        val extractor = openExtractor(inputPath)
        try {
            val index = audioTrack(extractor) ?: return null
            val format = extractor.getTrackFormat(index)
            val mime =
                format.getString(MediaFormat.KEY_MIME)
                    ?: throw FlutterError("unsupported", "Audio track has no mime", null)
            return if (isAac(mime)) {
                readAac(extractor, index, format)
            } else {
                transcodeAac(extractor, index, format, mime)
            }
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun readAac(extractor: MediaExtractor, index: Int, format: MediaFormat): AudioTrack {
        extractor.selectTrack(index)
        val samples = ArrayList<Sample>()
        val buffer = ByteBuffer.allocate(256 * 1024)
        while (true) {
            throwIfCancelled()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            val data = ByteArray(size)
            buffer.position(0)
            buffer.get(data, 0, size)
            samples.add(Sample(data, extractor.sampleTime.coerceAtLeast(0L), 0))
            extractor.advance()
            buffer.clear()
        }
        if (samples.isEmpty()) {
            return AudioTrack(format, samples)
        }
        return AudioTrack(format, samples)
    }

    private fun transcodeAac(
        extractor: MediaExtractor,
        index: Int,
        format: MediaFormat,
        mime: String,
    ): AudioTrack {
        val sampleRate = positiveInt(format, MediaFormat.KEY_SAMPLE_RATE, 0)
        val channels = positiveInt(format, MediaFormat.KEY_CHANNEL_COUNT, 0)
        if (sampleRate <= 0 || channels <= 0 || channels > 2) {
            throw FlutterError(
                "unsupported",
                "Cannot transcode audio ($sampleRate Hz, $channels ch) to AAC",
                null,
            )
        }
        if (!MediaCodecs.hasEncoder(MediaFormat.MIMETYPE_AUDIO_AAC)) {
            throw FlutterError("unsupported", "No AAC encoder installed", null)
        }
        extractor.selectTrack(index)
        val pcm = ByteArrayOutputStream()
        val decoder =
            try {
                MediaCodec.createDecoderByType(mime)
            } catch (error: Exception) {
                throw FlutterError("unsupported", "No decoder for $mime", error.toString())
            }
        try {
            decoder.configure(format, null, null, 0)
            decoder.start()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            val decodeDeadline = android.os.SystemClock.elapsedRealtime() + 30_000L
            while (true) {
                throwIfCancelled()
                if (android.os.SystemClock.elapsedRealtime() > decodeDeadline) {
                    throw FlutterError("unsupported", "Audio decoder timed out", null)
                }
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer =
                            decoder.getInputBuffer(inIndex)
                                ?: throw FlutterError("unsupported", "Audio input buffer missing", null)
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(
                                inIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(
                                inIndex,
                                0,
                                size,
                                extractor.sampleTime.coerceAtLeast(0L),
                                0,
                            )
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    if (info.size > 0) {
                        if (pcm.size() + info.size > MAX_PCM_BYTES) {
                            throw FlutterError("unsupported", "Audio is too long to transcode", null)
                        }
                        val buffer = decoder.getOutputBuffer(outIndex)
                        if (buffer != null) {
                            val chunk = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(chunk)
                            pcm.write(chunk)
                        }
                    }
                    val eos = flag(info.flags, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (eos) break
                }
            }
        } catch (error: FlutterError) {
            throw error
        } catch (error: Exception) {
            throw FlutterError("unsupported", error.message ?: "Audio decode failed", error.toString())
        } finally {
            releaseCodec(decoder)
        }
        val raw = pcm.toByteArray()
        val frameBytes = channels * 2
        if (raw.size < frameBytes) {
            throw FlutterError("unsupported", "Audio decoder produced no PCM", null)
        }
        val pcmBytes = raw.size - (raw.size % frameBytes)
        val encoder =
            try {
                MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            } catch (error: Exception) {
                throw FlutterError("unsupported", "No AAC encoder installed", error.toString())
            }
        try {
            val encFormat =
                MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels)
            encFormat.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            encFormat.setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            encFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, max(pcmBytes, 16_384))
            encoder.configure(encFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            val samples = ArrayList<Sample>()
            var outFormat: MediaFormat? = null
            var offset = 0
            var queuedSamples = 0L
            var inputDone = false
            var spins = 0
            val info = MediaCodec.BufferInfo()
            while (!inputDone) {
                throwIfCancelled()
                val inIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex < 0) {
                    outFormat = drainAudio(encoder, info, samples, outFormat, untilEos = false)
                    spins += 1
                    if (spins > 500) {
                        throw FlutterError("unsupported", "AAC encoder stalled", null)
                    }
                    continue
                }
                spins = 0
                val buffer =
                    encoder.getInputBuffer(inIndex)
                        ?: throw FlutterError("unsupported", "AAC input buffer missing", null)
                buffer.clear()
                val room = buffer.capacity() - (buffer.capacity() % frameBytes)
                val count = minOf(room, pcmBytes - offset)
                if (count <= 0) {
                    encoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    buffer.put(raw, offset, count)
                    val pts = queuedSamples * 1_000_000L / sampleRate
                    encoder.queueInputBuffer(inIndex, 0, count, pts, 0)
                    queuedSamples += count / frameBytes
                    offset += count
                    if (offset >= pcmBytes) {
                        // EOS is queued on the next iteration once the buffer is free.
                    }
                }
                outFormat = drainAudio(encoder, info, samples, outFormat, untilEos = false)
            }
            outFormat = drainAudio(encoder, info, samples, outFormat, untilEos = true)
            val muxFormat =
                outFormat ?: throw FlutterError("unsupported", "AAC encoder produced no format", null)
            if (samples.isEmpty()) {
                throw FlutterError("unsupported", "AAC encoder produced no samples", null)
            }
            return AudioTrack(muxFormat, samples)
        } catch (error: FlutterError) {
            throw error
        } catch (error: Exception) {
            throw FlutterError("unsupported", error.message ?: "AAC encode failed", error.toString())
        } finally {
            releaseCodec(encoder)
        }
    }

    private fun drainAudio(
        encoder: MediaCodec,
        info: MediaCodec.BufferInfo,
        samples: MutableList<Sample>,
        format: MediaFormat?,
        untilEos: Boolean,
    ): MediaFormat? {
        var seen = format
        val deadline = android.os.SystemClock.elapsedRealtime() + if (untilEos) 15_000L else 0L
        while (true) {
            throwIfCancelled()
            val index = encoder.dequeueOutputBuffer(info, if (untilEos) TIMEOUT_US else 0L)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEos) return seen
                    if (android.os.SystemClock.elapsedRealtime() > deadline) {
                        throw FlutterError("unsupported", "AAC encoder timed out", null)
                    }
                }

                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (seen == null) seen = encoder.outputFormat
                }

                index >= 0 -> {
                    val eos = flag(info.flags, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    val config = flag(info.flags, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
                    if (info.size > 0 && !config) {
                        val buffer = encoder.getOutputBuffer(index)
                        if (buffer != null) {
                            val data = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(data)
                            samples.add(Sample(data, info.presentationTimeUs.coerceAtLeast(0L), 0))
                        }
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (eos) return seen
                }
            }
        }
    }

    private fun writeSamples(muxer: MediaMuxer, track: Int, samples: List<Sample>) {
        var lastPts = -1L
        for (sample in samples) {
            var pts = sample.pts
            if (pts <= lastPts) {
                pts = lastPts + 1
            }
            lastPts = pts
            val info = MediaCodec.BufferInfo()
            info.offset = 0
            info.size = sample.data.size
            info.presentationTimeUs = pts
            info.flags = sample.flags
            muxer.writeSampleData(track, ByteBuffer.wrap(sample.data), info)
        }
    }

    private fun openEncoder(
        mime: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        iFrameSeconds: Float,
    ): OpenEncoder {
        val all = MediaCodecs.encoders(mime)
        if (all.isEmpty()) {
            throw FlutterError("unsupported", "No encoder for $mime", null)
        }
        val supported = all.filter { MediaCodecs.supportsSize(it, mime, width, height) }
        val ordered = if (supported.isNotEmpty()) supported else all
        var last: Exception? = null
        for (info in ordered) {
            val colors = MediaCodecs.colorFormats(info, mime)
            for (color in colors) {
                var codec: MediaCodec? = null
                try {
                    codec = MediaCodec.createByCodecName(info.name)
                    val format = MediaFormat.createVideoFormat(mime, width, height)
                    format.setInteger(MediaFormat.KEY_COLOR_FORMAT, color)
                    format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                    format.setInteger(MediaFormat.KEY_FRAME_RATE, fps.coerceAtLeast(1))
                    if (Build.VERSION.SDK_INT >= 25) {
                        format.setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameSeconds.coerceAtLeast(0.01f))
                    } else {
                        format.setInteger(
                            MediaFormat.KEY_I_FRAME_INTERVAL,
                            iFrameSeconds.toInt().coerceAtLeast(1),
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                    }
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    codec.start()
                    return OpenEncoder(
                        codec = codec,
                        hardware = MediaCodecs.isHardware(info),
                        colorFormat = color,
                        width = width,
                        height = height,
                    )
                } catch (error: Exception) {
                    last = error
                    releaseCodec(codec)
                }
            }
        }
        throw FlutterError(
            "encode",
            last?.message ?: "Encoder init failed",
            last?.toString(),
        )
    }

    private fun openExtractor(path: String): MediaExtractor {
        val extractor = MediaExtractor()
        try {
            if (path.startsWith("content://")) {
                val uri = path.toUri()
                try {
                    extractor.setDataSource(context, uri, null)
                } catch (error: Exception) {
                    if (isNotFound(error)) {
                        throw FlutterError("notFound", "Video not found: $path", null)
                    }
                    if (isSecurity(error)) {
                        throw FlutterError("io", error.message ?: "Cannot read $path", null)
                    }
                    throw FlutterError(
                        "decode",
                        error.message ?: "Unable to read video",
                        error.toString(),
                    )
                }
            } else {
                val file = File(path)
                if (!file.exists()) {
                    throw FlutterError("notFound", "Video not found: $path", null)
                }
                if (file.isDirectory || !file.isFile) {
                    throw FlutterError("io", "Video path is not a file: $path", null)
                }
                try {
                    extractor.setDataSource(path)
                } catch (error: Exception) {
                    throw FlutterError("decode", error.message ?: "Unable to read video", error.toString())
                }
            }
            if (extractor.trackCount <= 0) {
                throw FlutterError("decode", "No tracks in $path", null)
            }
            return extractor
        } catch (error: FlutterError) {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
            throw error
        }
    }

    private fun videoTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) return i
        }
        throw FlutterError("decode", "No video track", null)
    }

    private fun audioTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return null
    }

    private fun throwIfCancelled() {
        if (isCancelled()) {
            throw FlutterError("cancelled", "Cancelled", null)
        }
    }

    private fun isNotFound(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is FileNotFoundException) return true
            val message = current.message?.lowercase() ?: ""
            if (message.contains("no such file") || message.contains("enoent")) return true
            current = current.cause
        }
        return false
    }

    private fun isSecurity(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is SecurityException) return true
            current = current.cause
        }
        return false
    }

    private fun releaseCodec(codec: MediaCodec?) {
        if (codec == null) return
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        try {
            codec.release()
        } catch (_: Exception) {
        }
    }

    private fun isAac(mime: String): Boolean {
        return mime.equals(MediaFormat.MIMETYPE_AUDIO_AAC, ignoreCase = true) ||
            mime.equals("audio/mp4a", ignoreCase = true)
    }

    private fun flag(flags: Int, mask: Int): Boolean = (flags and mask) != 0

    private fun positiveInt(format: MediaFormat, key: String, fallback: Int): Int {
        if (!format.containsKey(key)) return fallback
        return try {
            val value = format.getInteger(key)
            if (value > 0) value else fallback
        } catch (_: Exception) {
            fallback
        }
    }

    private fun positiveLong(format: MediaFormat, key: String, fallback: Long): Long {
        if (!format.containsKey(key)) return fallback
        return try {
            val value = format.getLong(key)
            if (value > 0L) value else fallback
        } catch (_: Exception) {
            fallback
        }
    }

    private fun normalizePath(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.startsWith("file://")) {
            return trimmed.toUri().path ?: trimmed.removePrefix("file://")
        }
        return trimmed
    }

    private data class Sample(val data: ByteArray, val pts: Long, val flags: Int)

    private data class AudioTrack(val format: MediaFormat, val samples: List<Sample>)

    private class OpenEncoder(
        val codec: MediaCodec,
        val hardware: Boolean,
        val colorFormat: Int,
        val width: Int,
        val height: Int,
        var format: MediaFormat? = null,
    )

    companion object {
        private const val TIMEOUT_US = 10_000L
        private const val MAX_PCM_BYTES = 64 * 1024 * 1024

        fun queryCapabilities(): VideoCapabilitiesMsg = MediaCodecs.queryVideoCapabilities()
    }
}

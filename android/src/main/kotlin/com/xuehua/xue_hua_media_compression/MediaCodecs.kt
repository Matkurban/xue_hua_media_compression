package com.xuehua.xue_hua_media_compression

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * MediaCodec discovery shared by image (HEIC) and video.
 *
 * Hardware codecs are preferred. Software codecs stay in the list so
 * emulators and devices without a hardware encoder can still encode.
 */
internal object MediaCodecs {
    fun queryVideoCapabilities(): VideoCapabilitiesMsg {
        val codecs = mutableListOf<String>()
        if (hasEncoder(MediaFormat.MIMETYPE_VIDEO_AVC)) {
            codecs.add("h264")
        }
        if (hasEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)) {
            codecs.add("h265")
        }
        val hardware =
            hasHardwareEncoder(MediaFormat.MIMETYPE_VIDEO_AVC) ||
                hasHardwareEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)
        return VideoCapabilitiesMsg(
            encoderName = if (hardware) "MediaCodecHW" else null,
            codecs = codecs,
            acceptsContentUri = true,
        )
    }

    fun hasEncoder(mime: String): Boolean = encoders(mime).isNotEmpty()

    fun hasDecoder(mime: String): Boolean = decoders(mime).isNotEmpty()

    fun hasHardwareEncoder(mime: String): Boolean = encoders(mime).any { isHardware(it) }

    fun encoders(mime: String): List<MediaCodecInfo> = codecs(mime, encoder = true)

    fun decoders(mime: String): List<MediaCodecInfo> = codecs(mime, encoder = false)

    fun supportsSize(info: MediaCodecInfo, mime: String, width: Int, height: Int): Boolean {
        return try {
            val video = info.getCapabilitiesForType(mime).videoCapabilities ?: return false
            video.isSizeSupported(width, height)
        } catch (_: Exception) {
            false
        }
    }

    fun colorFormats(info: MediaCodecInfo, mime: String): List<Int> {
        val have =
            try {
                info.getCapabilitiesForType(mime).colorFormats.toSet()
            } catch (_: Exception) {
                return emptyList()
            }
        return preferredColorFormats.filter { have.contains(it) }
    }

    fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return info.isHardwareAccelerated
        }
        val name = info.name.lowercase()
        if (name.startsWith("omx.google.")) return false
        if (name.startsWith("c2.android.")) return false
        if (name.contains("software")) return false
        if (name.contains(".sw.")) return false
        return true
    }

    fun outputSize(srcWidth: Int, srcHeight: Int, maxDimension: Int?): Pair<Int, Int> {
        var width = max(srcWidth, 1)
        var height = max(srcHeight, 1)
        if (maxDimension != null && max(width, height) > maxDimension) {
            val scale = maxDimension.toDouble() / max(width, height).toDouble()
            width = (width * scale).roundToInt().coerceAtLeast(1)
            height = (height * scale).roundToInt().coerceAtLeast(1)
        }
        return evenDimension(width, maxDimension) to evenDimension(height, maxDimension)
    }

    private fun codecs(mime: String, encoder: Boolean): List<MediaCodecInfo> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return list.codecInfos
            .filter { info ->
                info.isEncoder == encoder &&
                    info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
            .sortedWith(compareByDescending<MediaCodecInfo> { isHardware(it) }.thenBy { it.name })
    }

    private fun evenDimension(value: Int, maxDimension: Int?): Int {
        var size = value
        if (size % 2 != 0) {
            size -= 1
        }
        if (maxDimension != null && size > maxDimension) {
            size = maxDimension - (maxDimension % 2)
        }
        if (size < 2) {
            size = 2
        }
        return size
    }

    private val preferredColorFormats =
        intArrayOf(
            CodecCapabilities.COLOR_FormatYUV420Flexible,
            CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            CodecCapabilities.COLOR_FormatYUV420Planar,
            CodecCapabilities.COLOR_FormatYUV420PackedSemiPlanar,
            CodecCapabilities.COLOR_FormatYUV420PackedPlanar,
        )
}

package com.xuehua.xue_hua_media_compression

import android.media.Image
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaFormat
import java.nio.ByteBuffer

/**
 * Tightly packed I420 helpers. Decoder images and codec buffers are converted
 * into this layout, then copied into the encoder (scaled, even-sized).
 */
internal object Yuv {
    fun allocate(width: Int, height: Int): ByteArray {
        val chromaW = width / 2
        val chromaH = height / 2
        return ByteArray(width * height + chromaW * chromaH * 2)
    }

    fun readImage(image: Image, width: Int, height: Int, out: ByteArray) {
        val crop = image.cropRect
        val planes = image.planes
        copyFromPlane(planes[0], crop.left, crop.top, width, height, out, 0, width)
        val chromaW = width / 2
        val chromaH = height / 2
        val uOffset = width * height
        val vOffset = uOffset + chromaW * chromaH
        copyFromPlane(
            planes[1],
            crop.left / 2,
            crop.top / 2,
            chromaW,
            chromaH,
            out,
            uOffset,
            chromaW,
        )
        copyFromPlane(
            planes[2],
            crop.left / 2,
            crop.top / 2,
            chromaW,
            chromaH,
            out,
            vOffset,
            chromaW,
        )
    }

    fun readCodecBuffer(
        buffer: ByteBuffer,
        offset: Int,
        format: MediaFormat,
        width: Int,
        height: Int,
        out: ByteArray,
    ) {
        val color =
            if (format.containsKey(MediaFormat.KEY_COLOR_FORMAT)) {
                format.getInteger(MediaFormat.KEY_COLOR_FORMAT)
            } else {
                CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            }
        var stride = width
        if (format.containsKey(MediaFormat.KEY_STRIDE)) {
            stride = format.getInteger(MediaFormat.KEY_STRIDE).coerceAtLeast(width)
        }
        var slice = height
        if (format.containsKey(MediaFormat.KEY_SLICE_HEIGHT)) {
            slice = format.getInteger(MediaFormat.KEY_SLICE_HEIGHT).coerceAtLeast(height)
        }
        val src = buffer.duplicate()
        when (color) {
            CodecCapabilities.COLOR_FormatYUV420Planar,
            CodecCapabilities.COLOR_FormatYUV420PackedPlanar,
            -> readPlanar(src, offset, stride, slice, width, height, out)

            else -> readSemiPlanar(src, offset, stride, slice, width, height, out)
        }
    }

    fun writeImage(i420: ByteArray, srcW: Int, srcH: Int, image: Image, dstW: Int, dstH: Int) {
        val crop = image.cropRect
        val planes = image.planes
        writePlane(i420, 0, srcW, srcW, srcH, planes[0], crop.left, crop.top, dstW, dstH)
        val chromaSrcW = srcW / 2
        val chromaSrcH = srcH / 2
        val uOffset = srcW * srcH
        val vOffset = uOffset + chromaSrcW * chromaSrcH
        writePlane(
            i420,
            uOffset,
            chromaSrcW,
            chromaSrcW,
            chromaSrcH,
            planes[1],
            crop.left / 2,
            crop.top / 2,
            dstW / 2,
            dstH / 2,
        )
        writePlane(
            i420,
            vOffset,
            chromaSrcW,
            chromaSrcW,
            chromaSrcH,
            planes[2],
            crop.left / 2,
            crop.top / 2,
            dstW / 2,
            dstH / 2,
        )
    }

    fun writeBuffer(
        i420: ByteArray,
        srcW: Int,
        srcH: Int,
        dst: ByteBuffer,
        dstW: Int,
        dstH: Int,
        colorFormat: Int,
    ) {
        val needed = dstW * dstH * 3 / 2
        if (dst.capacity() < needed) {
            throw FlutterError("encode", "Encoder buffer is smaller than the frame", null)
        }
        if (colorFormat == CodecCapabilities.COLOR_FormatYUV420Planar ||
            colorFormat == CodecCapabilities.COLOR_FormatYUV420PackedPlanar
        ) {
            writePlanar(i420, srcW, srcH, dst, dstW, dstH)
        } else {
            writeSemiPlanar(i420, srcW, srcH, dst, dstW, dstH)
        }
    }

    private fun copyFromPlane(
        plane: Image.Plane,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        out: ByteArray,
        outOffset: Int,
        outStride: Int,
    ) {
        if (width <= 0 || height <= 0) return
        val buffer = plane.buffer.duplicate()
        val base = buffer.position()
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (pixelStride == 1) {
            for (y in 0 until height) {
                val src = base + (originY + y) * rowStride + originX
                val dst = outOffset + y * outStride
                if (src < 0 || src + width > buffer.capacity() || dst + width > out.size) {
                    continue
                }
                buffer.position(src)
                buffer.get(out, dst, width)
            }
            return
        }
        for (y in 0 until height) {
            val dst = outOffset + y * outStride
            for (x in 0 until width) {
                val index = base + (originY + y) * rowStride + (originX + x) * pixelStride
                out[dst + x] =
                    if (index in 0 until buffer.capacity()) {
                        buffer.get(index)
                    } else {
                        0
                    }
            }
        }
    }

    private fun writePlane(
        src: ByteArray,
        srcOffset: Int,
        srcStride: Int,
        srcW: Int,
        srcH: Int,
        plane: Image.Plane,
        dstX: Int,
        dstY: Int,
        dstW: Int,
        dstH: Int,
    ) {
        if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return
        val buffer = plane.buffer.duplicate()
        val base = buffer.position()
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (srcW == dstW && srcH == dstH && pixelStride == 1) {
            for (y in 0 until dstH) {
                val dstPos = base + (dstY + y) * rowStride + dstX
                val srcPos = srcOffset + y * srcStride
                if (dstPos < 0 || dstPos + dstW > buffer.capacity() || srcPos + dstW > src.size) {
                    continue
                }
                buffer.position(dstPos)
                buffer.put(src, srcPos, dstW)
            }
            return
        }
        for (y in 0 until dstH) {
            val sy = y * srcH / dstH
            val srcRow = srcOffset + sy * srcStride
            for (x in 0 until dstW) {
                val sx = x * srcW / dstW
                val index = base + (dstY + y) * rowStride + (dstX + x) * pixelStride
                if (index in 0 until buffer.capacity() && srcRow + sx < src.size) {
                    buffer.put(index, src[srcRow + sx])
                }
            }
        }
    }

    private fun readPlanar(
        src: ByteBuffer,
        offset: Int,
        stride: Int,
        sliceHeight: Int,
        width: Int,
        height: Int,
        out: ByteArray,
    ) {
        val chromaW = width / 2
        val chromaH = height / 2
        val chromaStride = stride / 2
        val uBase = offset + stride * sliceHeight
        val vBase = uBase + chromaStride * (sliceHeight / 2)
        copyRows(src, offset, stride, out, 0, width, width, height)
        copyRows(src, uBase, chromaStride, out, width * height, chromaW, chromaW, chromaH)
        copyRows(
            src,
            vBase,
            chromaStride,
            out,
            width * height + chromaW * chromaH,
            chromaW,
            chromaW,
            chromaH,
        )
    }

    private fun readSemiPlanar(
        src: ByteBuffer,
        offset: Int,
        stride: Int,
        sliceHeight: Int,
        width: Int,
        height: Int,
        out: ByteArray,
    ) {
        val chromaW = width / 2
        val chromaH = height / 2
        val uOffset = width * height
        val vOffset = uOffset + chromaW * chromaH
        copyRows(src, offset, stride, out, 0, width, width, height)
        val uvBase = offset + stride * sliceHeight
        for (y in 0 until chromaH) {
            for (x in 0 until chromaW) {
                val index = uvBase + y * stride + x * 2
                val u = if (index in 0 until src.capacity()) src.get(index) else 0
                val v = if (index + 1 < src.capacity()) src.get(index + 1) else 0
                out[uOffset + y * chromaW + x] = u
                out[vOffset + y * chromaW + x] = v
            }
        }
    }

    private fun copyRows(
        src: ByteBuffer,
        srcOffset: Int,
        srcStride: Int,
        dst: ByteArray,
        dstOffset: Int,
        dstStride: Int,
        width: Int,
        height: Int,
    ) {
        val view = src.duplicate()
        for (y in 0 until height) {
            val from = srcOffset + y * srcStride
            val to = dstOffset + y * dstStride
            if (from < 0 || from + width > view.capacity() || to + width > dst.size) {
                continue
            }
            view.position(from)
            view.get(dst, to, width)
        }
    }

    private fun writePlanar(
        i420: ByteArray,
        srcW: Int,
        srcH: Int,
        dst: ByteBuffer,
        dstW: Int,
        dstH: Int,
    ) {
        dst.clear()
        writeScaledPlane(i420, 0, srcW, srcW, srcH, dst, 0, dstW, dstW, dstH)
        val chromaSrcW = srcW / 2
        val chromaSrcH = srcH / 2
        val uOffset = srcW * srcH
        val chromaDstW = dstW / 2
        val chromaDstH = dstH / 2
        val dstU = dstW * dstH
        writeScaledPlane(
            i420,
            uOffset,
            chromaSrcW,
            chromaSrcW,
            chromaSrcH,
            dst,
            dstU,
            chromaDstW,
            chromaDstW,
            chromaDstH,
        )
        writeScaledPlane(
            i420,
            uOffset + chromaSrcW * chromaSrcH,
            chromaSrcW,
            chromaSrcW,
            chromaSrcH,
            dst,
            dstU + chromaDstW * chromaDstH,
            chromaDstW,
            chromaDstW,
            chromaDstH,
        )
    }

    private fun writeSemiPlanar(
        i420: ByteArray,
        srcW: Int,
        srcH: Int,
        dst: ByteBuffer,
        dstW: Int,
        dstH: Int,
    ) {
        dst.clear()
        writeScaledPlane(i420, 0, srcW, srcW, srcH, dst, 0, dstW, dstW, dstH)
        val chromaSrcW = srcW / 2
        val chromaSrcH = srcH / 2
        val uOffset = srcW * srcH
        val vOffset = uOffset + chromaSrcW * chromaSrcH
        val chromaDstW = dstW / 2
        val chromaDstH = dstH / 2
        val ySize = dstW * dstH
        for (y in 0 until chromaDstH) {
            val sy = if (chromaSrcH == 0) 0 else y * chromaSrcH / chromaDstH
            for (x in 0 until chromaDstW) {
                val sx = if (chromaSrcW == 0) 0 else x * chromaSrcW / chromaDstW
                val out = ySize + y * dstW + x * 2
                if (out + 1 < dst.capacity()) {
                    dst.put(out, i420[uOffset + sy * chromaSrcW + sx])
                    dst.put(out + 1, i420[vOffset + sy * chromaSrcW + sx])
                }
            }
        }
    }

    private fun writeScaledPlane(
        src: ByteArray,
        srcOffset: Int,
        srcStride: Int,
        srcW: Int,
        srcH: Int,
        dst: ByteBuffer,
        dstOffset: Int,
        dstStride: Int,
        dstW: Int,
        dstH: Int,
    ) {
        if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return
        if (srcW == dstW && srcH == dstH && srcStride == dstW && dstStride == dstW) {
            val view = dst.duplicate()
            view.position(dstOffset)
            view.put(src, srcOffset, dstW * dstH)
            return
        }
        for (y in 0 until dstH) {
            val sy = y * srcH / dstH
            val srcRow = srcOffset + sy * srcStride
            val dstRow = dstOffset + y * dstStride
            for (x in 0 until dstW) {
                val sx = x * srcW / dstW
                if (dstRow + x < dst.capacity()) {
                    dst.put(dstRow + x, src[srcRow + sx])
                }
            }
        }
    }
}

//! 视频像素缩放（CPU）：输出尺寸计算与 NV12 缩放。

/// 等比缩放到最大边长（宽高对齐到偶数）。
pub(crate) fn scale_dims(w: u32, h: u32, max: Option<u32>) -> (u32, u32) {
    match max {
        Some(m) if w.max(h) > m => {
            let ratio = m as f64 / w.max(h) as f64;
            (
                ((w as f64 * ratio) as u32) & !1,
                ((h as f64 * ratio) as u32) & !1,
            )
        }
        _ => (w & !1, h & !1),
    }
}

/// NV12 最近邻缩放（CPU）。
pub(crate) fn scale_nv12(src: &[u8], src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) -> Vec<u8> {
    if src_w == dst_w && src_h == dst_h {
        return src.to_vec();
    }
    let src_y_size = (src_w * src_h) as usize;
    let dst_y_size = (dst_w * dst_h) as usize;
    let mut dst = vec![0u8; dst_y_size + (dst_w * dst_h / 2) as usize];

    for dy in 0..dst_h {
        let sy = (dy as f32 * src_h as f32 / dst_h as f32) as u32;
        let sy = sy.min(src_h - 1);
        for dx in 0..dst_w {
            let sx = (dx as f32 * src_w as f32 / dst_w as f32) as u32;
            let sx = sx.min(src_w - 1);
            dst[(dy * dst_w + dx) as usize] = src[(sy * src_w + sx) as usize];
        }
    }

    let src_uv_off = src_y_size;
    let dst_uv_off = dst_y_size;
    let dst_uv_h = dst_h / 2;
    let dst_uv_w = dst_w;
    for dy in 0..dst_uv_h {
        let sy = (dy as f32 * (src_h / 2) as f32 / dst_uv_h as f32) as u32;
        let sy = sy.min(src_h / 2 - 1);
        for dx in 0..dst_uv_w / 2 {
            let sx = (dx as f32 * (src_w / 2) as f32 / (dst_uv_w / 2) as f32) as u32;
            let sx = sx.min(src_w / 2 - 1);
            let src_idx = src_uv_off + ((sy * src_w) + sx * 2) as usize;
            let dst_idx = dst_uv_off + ((dy * dst_uv_w) + dx * 2) as usize;
            if src_idx + 1 < src.len() && dst_idx + 1 < dst.len() {
                dst[dst_idx] = src[src_idx];
                dst[dst_idx + 1] = src[src_idx + 1];
            }
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_dims_even_align_without_max() {
        assert_eq!(scale_dims(641, 481, None), (640, 480));
    }

    #[test]
    fn scale_dims_respects_max_dimension() {
        assert_eq!(scale_dims(1920, 1080, Some(720)), (720, 404));
    }

    #[test]
    fn scale_nv12_identity() {
        let w = 4u32;
        let h = 4u32;
        let y = w * h;
        let uv = w * h / 2;
        let src: Vec<u8> = (0..y + uv).map(|i| i as u8).collect();
        let out = scale_nv12(&src, w, h, w, h);
        assert_eq!(out, src);
    }
}

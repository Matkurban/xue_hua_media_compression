//! 视频压缩各平台共用的 NAL/封装辅助函数。

use crate::api::traits::{MediaError, VideoCodec};

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

/// H.264 Annex-B 参数集。
pub(crate) struct H264ParamSets {
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}

/// H.265 Annex-B 参数集。
pub(crate) struct HevcParamSets {
    pub vps: Vec<u8>,
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}

/// 从 Annex-B 流中提取 H.264 SPS/PPS（含起始码的完整 NAL）。
pub(crate) fn extract_h264_param_sets(annex_b: &[u8]) -> H264ParamSets {
    let mut sps = Vec::new();
    let mut pps = Vec::new();
    for nal in iter_annex_b_nals_with_start(annex_b) {
        if nal.is_empty() {
            continue;
        }
        let nal_type = nal[if nal.starts_with(&[0, 0, 0, 1]) { 4 } else { 3 }] & 0x1F;
        match nal_type {
            7 if sps.is_empty() => sps = nal.to_vec(),
            8 if pps.is_empty() => pps = nal.to_vec(),
            _ => {}
        }
    }
    H264ParamSets { sps, pps }
}

/// 从 Annex-B 流中提取 H.265 VPS/SPS/PPS。
pub(crate) fn extract_hevc_param_sets(annex_b: &[u8]) -> HevcParamSets {
    let mut vps = Vec::new();
    let mut sps = Vec::new();
    let mut pps = Vec::new();
    for nal in iter_annex_b_nals_with_start(annex_b) {
        if nal.is_empty() {
            continue;
        }
        let header_off = if nal.starts_with(&[0, 0, 0, 1]) { 4 } else { 3 };
        if header_off >= nal.len() {
            continue;
        }
        let nal_type = (nal[header_off] >> 1) & 0x3F;
        match nal_type {
            32 if vps.is_empty() => vps = nal.to_vec(),
            33 if sps.is_empty() => sps = nal.to_vec(),
            34 if pps.is_empty() => pps = nal.to_vec(),
            _ => {}
        }
    }
    HevcParamSets { vps, sps, pps }
}

/// 按编码类型提取参数集，写入 MuxParams 用的切片。
pub(crate) fn extract_param_sets_for_codec(
    codec: VideoCodec,
    annex_b: &[u8],
) -> (Option<Vec<u8>>, Vec<u8>, Vec<u8>) {
    match codec {
        VideoCodec::H264 => {
            let ps = extract_h264_param_sets(annex_b);
            (None, ps.sps, ps.pps)
        }
        VideoCodec::H265 => {
            let ps = extract_hevc_param_sets(annex_b);
            (Some(ps.vps), ps.sps, ps.pps)
        }
    }
}

/// Annex-B -> AVCC（4 字节大端长度前缀）。
pub(crate) fn annex_b_to_avcc(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 16);
    for nal in iter_annex_b_nals(data) {
        let len = nal.len() as u32;
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(nal);
    }
    if out.is_empty() && !data.is_empty() {
        // 可能已是 AVCC
        return data.to_vec();
    }
    out
}

/// AVCC -> Annex-B。
pub(crate) fn avcc_to_annex_b(data: &[u8]) -> Vec<u8> {
    if data.starts_with(&[0, 0, 0, 1]) || data.starts_with(&[0, 0, 1]) {
        return data.to_vec();
    }
    let mut out = Vec::with_capacity(data.len() + 32);
    let mut i = 0;
    while i + 4 <= data.len() {
        let len = u32::from_be_bytes(data[i..i + 4].try_into().unwrap()) as usize;
        i += 4;
        if i + len > data.len() {
            break;
        }
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&data[i..i + len]);
        i += len;
    }
    out
}

/// 去掉单个 NAL 的 Annex-B 起始码。
pub(crate) fn strip_annex_b_start_code(nal: &[u8]) -> &[u8] {
    if nal.starts_with(&[0, 0, 0, 1]) {
        &nal[4..]
    } else if nal.starts_with(&[0, 0, 1]) {
        &nal[3..]
    } else {
        nal
    }
}

/// 遍历 Annex-B 流中的 NAL（不含起始码）。
pub(crate) fn iter_annex_b_nals(data: &[u8]) -> Vec<&[u8]> {
    let mut nals = Vec::new();
    let starts = find_annex_b_starts(data);
    for (idx, (pos, sc_len)) in starts.iter().enumerate() {
        let nal_start = pos + sc_len;
        let nal_end = if idx + 1 < starts.len() {
            starts[idx + 1].0
        } else {
            data.len()
        };
        if nal_start < nal_end {
            nals.push(&data[nal_start..nal_end]);
        }
    }
    nals
}

/// 遍历 Annex-B NAL（含起始码）。
fn iter_annex_b_nals_with_start(data: &[u8]) -> Vec<&[u8]> {
    let starts = find_annex_b_starts(data);
    let mut nals = Vec::new();
    for (idx, (pos, _)) in starts.iter().enumerate() {
        let nal_end = if idx + 1 < starts.len() {
            starts[idx + 1].0
        } else {
            data.len()
        };
        nals.push(&data[*pos..nal_end]);
    }
    nals
}

fn find_annex_b_starts(data: &[u8]) -> Vec<(usize, usize)> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.push((i, 3));
            i += 3;
        } else if i + 4 <= data.len()
            && data[i] == 0
            && data[i + 1] == 0
            && data[i + 2] == 0
            && data[i + 3] == 1
        {
            starts.push((i, 4));
            i += 4;
        } else {
            i += 1;
        }
    }
    starts
}

/// 构建 ISO/IEC 14496-15 HEVCDecoderConfigurationRecord（hvcC 负载，不含 box 头）。
pub(crate) fn build_hvcc_payload(vps: &[u8], sps: &[u8], pps: &[u8]) -> Vec<u8> {
    let vps_raw = strip_annex_b_start_code(vps);
    let sps_raw = strip_annex_b_start_code(sps);
    let pps_raw = strip_annex_b_start_code(pps);

    let profile_space = 0u8;
    let profile_idc = sps_raw.get(1).copied().unwrap_or(1);
    let compat = u32::from_be_bytes([
        sps_raw.get(2).copied().unwrap_or(0),
        sps_raw.get(3).copied().unwrap_or(0),
        sps_raw.get(4).copied().unwrap_or(0),
        sps_raw.get(5).copied().unwrap_or(0),
    ]);
    let level = sps_raw.get(12).copied().unwrap_or(120);
    let constraint = [0u8; 6];

    let mut out = Vec::new();
    out.push(1); // configurationVersion
    out.push((profile_space << 6) | (profile_idc & 0x1F));
    out.extend_from_slice(&compat.to_be_bytes());
    out.extend_from_slice(&constraint);
    out.push(level);
    out.extend_from_slice(&0xF000u16.to_be_bytes()); // min_spatial_segmentation_idc
    out.push(0xFC); // parallelismType
    out.push(0xFD); // chromaFormat = 4:2:0
    out.push(0xF8); // bitDepthLumaMinus8 = 0
    out.push(0xF8); // bitDepthChromaMinus8 = 0
    out.extend_from_slice(&0u16.to_be_bytes()); // avgFrameRate
    out.push(0x0F); // constantFrameRate + numTemporalLayers + temporalIdNested + lengthSizeMinusOne(3)
    out.push(3); // numOfArrays

    for (nal_type, nal) in [(32u8, vps_raw), (33, sps_raw), (34, pps_raw)] {
        if nal.is_empty() {
            continue;
        }
        out.push(0x80 | nal_type); // array_completeness + NAL type
        out.extend_from_slice(&1u16.to_be_bytes()); // numNalus
        out.extend_from_slice(&(nal.len() as u16).to_be_bytes());
        out.extend_from_slice(nal);
    }
    out
}

/// 将 mp4 crate 写出的最小 hvcC box 替换为完整配置，并修正父 box 尺寸。
pub(crate) fn patch_hvcc_in_mp4(
    path: &str,
    vps: &[u8],
    sps: &[u8],
    pps: &[u8],
) -> Result<(), MediaError> {
    let mut data = std::fs::read(path)?;
    let hvcc_payload = build_hvcc_payload(vps, sps, pps);
    let new_box = build_mp4_box(b"hvcC", &hvcc_payload);

    let needle = b"hvcC";
    let pos = data
        .windows(4)
        .position(|w| w == needle)
        .ok_or_else(|| MediaError::Mux("MP4 中未找到 hvcC box".into()))?;
    let box_start = pos - 4;
    let old_size =
        u32::from_be_bytes(data[box_start..box_start + 4].try_into().unwrap()) as usize;
    let delta = new_box.len() as i64 - old_size as i64;
    if delta != 0 {
        update_containing_box_sizes(&mut data, box_start, delta);
    }
    data.splice(box_start..box_start + old_size, new_box);
    std::fs::write(path, &data)?;
    Ok(())
}

fn build_mp4_box(fourcc: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let size = (8 + payload.len()) as u32;
    let mut out = Vec::with_capacity(size as usize);
    out.extend_from_slice(&size.to_be_bytes());
    out.extend_from_slice(fourcc);
    out.extend_from_slice(payload);
    out
}

fn is_container_box(typ: &[u8]) -> bool {
    matches!(
        typ,
        b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"stsd" | b"hev1" | b"hvc1" | b"uuid"
    )
}

fn update_containing_box_sizes(data: &mut [u8], target_pos: usize, delta: i64) {
    fn walk(data: &mut [u8], start: usize, end: usize, target: usize, delta: i64) {
        let mut pos = start;
        while pos + 8 <= end {
            let size = u32::from_be_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
            if size < 8 {
                break;
            }
            let box_end = pos + size;
            if box_end > end {
                break;
            }
            if pos < target && target < box_end {
                let new_size = (size as i64 + delta) as u32;
                data[pos..pos + 4].copy_from_slice(&new_size.to_be_bytes());
            }
            let typ = &data[pos + 4..pos + 8];
            if is_container_box(typ) {
                walk(data, pos + 8, box_end, target, delta);
            }
            pos = box_end;
        }
    }
    walk(data, 0, data.len(), target_pos, delta);
}

/// NV12 双线性缩放（CPU）。
pub(crate) fn scale_nv12(
    src: &[u8],
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
) -> Vec<u8> {
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

/// 从 mp4 容器读取视频轨元数据（全平台可用）。
pub(crate) fn read_mp4_video_metadata(path: &str) -> Result<(u32, u32, u32), MediaError> {
    use mp4::{Mp4Reader, TrackType};
    use std::fs::File;
    use std::io::BufReader;

    let file_size = std::fs::metadata(path)?.len();
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mp4 = Mp4Reader::read_header(reader, file_size)
        .map_err(|e| MediaError::Decode(e.to_string()))?;

    for track_id in mp4.tracks().keys() {
        let track = mp4.tracks().get(track_id).unwrap();
        let track_type = track
            .track_type()
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        if track_type != TrackType::Video {
            continue;
        }
        let width = track.width();
        let height = track.height();
        let duration_secs = track.duration().as_secs_f64();
        let sample_count = track.sample_count();
        let fps = if duration_secs > 0.0 {
            (sample_count as f64 / duration_secs).round() as u32
        } else {
            30
        };
        return Ok((width as u32, height as u32, fps.max(1)));
    }
    Err(MediaError::Decode("MP4 中未找到视频轨".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annex_b_roundtrip() {
        let annex = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 0, 1, 0x68, 0xce];
        let avcc = annex_b_to_avcc(&annex);
        let back = avcc_to_annex_b(&avcc);
        assert_eq!(back, annex);
    }

    #[test]
    fn extract_h264() {
        let annex = [0u8, 0, 0, 1, 0x67, 0x01, 0, 0, 0, 0, 1, 0x68, 0x02];
        let ps = extract_h264_param_sets(&annex);
        assert!(!ps.sps.is_empty());
        assert!(!ps.pps.is_empty());
    }

    #[test]
    fn extract_hevc() {
        let annex = [0u8, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 0, 1, 0x42, 0x01, 0, 0, 0, 1, 0x44, 0x01];
        let ps = extract_hevc_param_sets(&annex);
        assert!(!ps.vps.is_empty());
        assert!(!ps.sps.is_empty());
        assert!(!ps.pps.is_empty());
    }
}

//! 视频码流辅助：Annex-B / AVCC 转换、参数集提取、hvcC 构建与修补。

use crate::api::traits::{MediaError, VideoCodec};

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
pub(crate) fn annex_b_to_avcc(data: &[u8]) -> Result<Vec<u8>, MediaError> {
    let mut out = Vec::with_capacity(data.len() + 16);
    for nal in iter_annex_b_nals(data) {
        let len = nal.len() as u32;
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(nal);
    }
    if out.is_empty() && !data.is_empty() {
        if is_valid_avcc(data) {
            return Ok(data.to_vec());
        }
        return Err(MediaError::Mux(
            "无法识别的 NAL 格式：既非 Annex-B 也非 AVCC".into(),
        ));
    }
    Ok(out)
}

/// 判断缓冲区是否为完整的 AVCC（长度前缀 NAL 序列）。
fn is_valid_avcc(data: &[u8]) -> bool {
    if data.len() < 5 {
        return false;
    }
    let mut i = 0;
    let mut nals = 0;
    while i + 4 <= data.len() {
        let len = u32::from_be_bytes(data[i..i + 4].try_into().unwrap()) as usize;
        if len == 0 {
            return false;
        }
        i += 4;
        if i + len > data.len() {
            return false;
        }
        i += len;
        nals += 1;
    }
    nals > 0 && i == data.len()
}

/// H.264 Annex-B 流是否包含 IDR NAL（type 5）。
pub(crate) fn annex_b_has_idr_h264_nal(annex_b: &[u8]) -> bool {
    let mut i = 0;
    while i + 4 < annex_b.len() {
        if annex_b[i..].starts_with(&[0, 0, 0, 1]) {
            i += 4;
        } else if annex_b[i..].starts_with(&[0, 0, 1]) {
            i += 3;
        } else {
            i += 1;
            continue;
        }
        if i < annex_b.len() && (annex_b[i] & 0x1f) == 5 {
            return true;
        }
    }
    false
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

    let box_start = find_hvcc_box_start(&data)
        .ok_or_else(|| MediaError::Mux("MP4 中未找到 hvcC box".into()))?;
    let old_size = u32::from_be_bytes(data[box_start..box_start + 4].try_into().unwrap()) as usize;
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

/// 在 stsd → hvc1/hev1 子树内定位 hvcC box 起始偏移（含 box 头）。
fn find_hvcc_box_start(data: &[u8]) -> Option<usize> {
    find_box_start(data, 0, data.len(), None, b"hvcC", &[b"hvc1", b"hev1"])
}

fn find_box_start(
    data: &[u8],
    start: usize,
    end: usize,
    parent_type: Option<&[u8; 4]>,
    target: &[u8; 4],
    valid_parents: &[&[u8; 4]],
) -> Option<usize> {
    let mut pos = start;
    while pos + 8 <= end {
        let size = u32::from_be_bytes(data[pos..pos + 4].try_into().ok()?) as usize;
        if size < 8 {
            break;
        }
        let box_end = pos + size;
        if box_end > end {
            break;
        }
        let typ: &[u8; 4] = data[pos + 4..pos + 8].try_into().ok()?;
        if typ == target {
            let parent_ok = parent_type
                .map(|p| valid_parents.contains(&p))
                .unwrap_or(false);
            if parent_ok {
                return Some(pos);
            }
        }
        if should_recurse_into_box(typ) {
            let content_start = box_content_start(pos, typ);
            if let Some(found) = find_box_start(
                data,
                content_start,
                box_end,
                Some(typ),
                target,
                valid_parents,
            ) {
                return Some(found);
            }
        }
        pos = box_end;
    }
    None
}

fn should_recurse_into_box(typ: &[u8; 4]) -> bool {
    is_container_box(typ) || matches!(typ, b"stsd" | b"hvc1" | b"hev1" | b"avc1")
}

fn box_content_start(pos: usize, typ: &[u8; 4]) -> usize {
    match typ {
        b"stsd" => pos + 16,
        b"hvc1" | b"hev1" | b"avc1" => pos + 86,
        _ => pos + 8,
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annex_b_roundtrip() {
        let annex = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 0, 1, 0x68, 0xce];
        let avcc = annex_b_to_avcc(&annex).unwrap();
        let back = avcc_to_annex_b(&avcc);
        assert_eq!(back, annex);
    }

    #[test]
    fn annex_b_to_avcc_rejects_garbage() {
        let err = annex_b_to_avcc(&[0xde, 0xad, 0xbe, 0xef]).unwrap_err();
        assert!(matches!(err, MediaError::Mux(_)));
    }

    #[test]
    fn annex_b_to_avcc_accepts_valid_avcc_passthrough() {
        let annex = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f];
        let avcc = annex_b_to_avcc(&annex).unwrap();
        let again = annex_b_to_avcc(&avcc).unwrap();
        assert_eq!(again, avcc);
    }

    #[test]
    fn annex_b_has_idr_h264_detects_idr() {
        let idr = [0u8, 0, 0, 1, 0x65, 0x88];
        assert!(annex_b_has_idr_h264_nal(&idr));
        let trail = [0u8, 0, 0, 1, 0x41, 0x88];
        assert!(!annex_b_has_idr_h264_nal(&trail));
    }

    #[test]
    fn find_hvcc_ignores_false_positive_in_payload() {
        let mut stsd_payload = Vec::new();
        stsd_payload.extend_from_slice(&0u32.to_be_bytes());
        stsd_payload.extend_from_slice(&1u32.to_be_bytes());
        let mut hvc1_payload = vec![0u8; 78];
        let hvcc_box = build_mp4_box(b"hvcC", &[0x01, 0x02, 0x03, 0x04]);
        hvc1_payload.extend_from_slice(&hvcc_box);
        let hvc1_box = build_mp4_box(b"hvc1", &hvc1_payload);
        stsd_payload.extend_from_slice(&hvc1_box);
        let stsd_box = build_mp4_box(b"stsd", &stsd_payload);
        let stbl_box = build_mp4_box(b"stbl", &stsd_box);
        let minf_box = build_mp4_box(b"minf", &stbl_box);
        let mdia_box = build_mp4_box(b"mdia", &minf_box);
        let trak_box = build_mp4_box(b"trak", &mdia_box);
        let mut moov_payload = trak_box;
        moov_payload.extend_from_slice(b"fakehvcC");
        let moov_box = build_mp4_box(b"moov", &moov_payload);
        let ftyp_box = build_mp4_box(b"ftyp", b"isom");
        let mut file = Vec::new();
        file.extend_from_slice(&ftyp_box);
        file.extend_from_slice(&moov_box);
        let false_positive = file.windows(4).position(|w| w == b"hvcC").unwrap();
        let start = find_hvcc_box_start(&file).expect("hvcC inside hvc1");
        assert_eq!(&file[start + 4..start + 8], b"hvcC");
        assert_ne!(start, false_positive);
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
        let annex = [
            0u8, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 0, 1, 0x42, 0x01, 0, 0, 0, 1, 0x44, 0x01,
        ];
        let ps = extract_hevc_param_sets(&annex);
        assert!(!ps.vps.is_empty());
        assert!(!ps.sps.is_empty());
        assert!(!ps.pps.is_empty());
    }
}

//! 视频封装（Muxer）：用纯 Rust 的 `mp4` crate 把各平台硬编吐出的
//! H.264 / H.265 裸流（Annex-B）打包成标准 `.mp4` 文件。

use std::fs::File;
use std::io::{BufWriter, Seek, Write};

use mp4::{AvcConfig, HevcConfig, MediaConfig, Mp4Config, Mp4Writer, TrackConfig, TrackType};

use crate::api::traits::{MediaError, VideoCodec};
use crate::api::video_common::{annex_b_to_avcc, patch_hvcc_in_mp4, strip_annex_b_start_code};

/// 一帧编码输出。
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct EncodedFrame {
    pub data: Vec<u8>,
    pub is_keyframe: bool,
    pub duration: u32,
}

/// 封装所需的轨道元数据。
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MuxParams<'a> {
    pub codec: VideoCodec,
    pub width: u16,
    pub height: u16,
    pub timescale: u32,
    /// H.265 VPS（H.264 忽略）。
    pub vps: Option<&'a [u8]>,
    pub sps: &'a [u8],
    pub pps: &'a [u8],
}

/// 把一组编码帧封装为 MP4 文件。
pub(crate) fn mux_to_mp4(
    output_path: &str,
    params: &MuxParams,
    frames: &[EncodedFrame],
) -> Result<u64, MediaError> {
    if frames.is_empty() {
        return Err(MediaError::Mux("无编码帧可封装".into()));
    }

    let (major_brand, compatible) = match params.codec {
        VideoCodec::H264 => ("isom", vec!["isom", "iso2", "avc1", "mp41"]),
        VideoCodec::H265 => ("isom", vec!["isom", "iso2", "hvc1", "mp41"]),
    };

    let file = File::create(output_path)?;
    let writer = BufWriter::new(file);

    let config = Mp4Config {
        major_brand: str::parse(major_brand).unwrap(),
        minor_version: 512,
        compatible_brands: compatible
            .into_iter()
            .map(|b| str::parse(b).unwrap())
            .collect(),
        timescale: params.timescale,
    };

    let mut mp4_writer =
        Mp4Writer::write_start(writer, &config).map_err(|e| MediaError::Mux(e.to_string()))?;

    let track_conf = match params.codec {
        VideoCodec::H264 => TrackConfig {
            track_type: TrackType::Video,
            timescale: params.timescale,
            language: "und".to_string(),
            media_conf: MediaConfig::AvcConfig(AvcConfig {
                width: params.width,
                height: params.height,
                seq_param_set: strip_annex_b_start_code(params.sps).to_vec(),
                pic_param_set: strip_annex_b_start_code(params.pps).to_vec(),
            }),
        },
        VideoCodec::H265 => TrackConfig {
            track_type: TrackType::Video,
            timescale: params.timescale,
            language: "und".to_string(),
            media_conf: MediaConfig::HevcConfig(HevcConfig {
                width: params.width,
                height: params.height,
            }),
        },
    };

    mp4_writer
        .add_track(&track_conf)
        .map_err(|e| MediaError::Mux(e.to_string()))?;

    for f in frames {
        let avcc = annex_b_to_avcc(&f.data);
        let sample = mp4::Mp4Sample {
            start_time: 0,
            duration: f.duration,
            rendering_offset: 0,
            is_sync: f.is_keyframe,
            bytes: bytes::Bytes::from(avcc),
        };
        mp4_writer
            .write_sample(1, &sample)
            .map_err(|e| MediaError::Mux(e.to_string()))?;
    }

    mp4_writer
        .write_end()
        .map_err(|e| MediaError::Mux(e.to_string()))?;

    if params.codec == VideoCodec::H265 {
        let vps = params.vps.unwrap_or(params.sps);
        patch_hvcc_in_mp4(output_path, vps, params.sps, params.pps)?;
    }

    let meta = std::fs::metadata(output_path)?;
    Ok(meta.len())
}

#[allow(dead_code)]
fn _assert_seekable<W: Write + Seek>(_w: &Mp4Writer<W>) {}

//! 视频封装（Muxer）：用纯 Rust 的 `mp4` crate 把各平台硬编吐出的
//! H.264 / H.265 裸流（Annex-B）打包成标准 `.mp4` 文件。

use std::fs::File;
use std::io::{BufWriter, Seek, Write};

use mp4::{AvcConfig, HevcConfig, MediaConfig, Mp4Config, Mp4Writer, TrackConfig, TrackType};

use crate::api::traits::{MediaError, VideoCodec, VideoResult};
use crate::file_input::prepare_output_path;
use crate::video_bitstream::{annex_b_to_avcc, patch_hvcc_in_mp4, strip_annex_b_start_code};

/// MP4 轨道时间基（与 `frame_duration = TIMESCALE / fps` 一致）。
pub(crate) const TIMESCALE: u32 = 90_000;

/// 由帧率计算 MP4 时间基下的单帧 duration。
pub(crate) fn frame_duration_for_fps(fps: u32) -> u32 {
    TIMESCALE / fps.max(1)
}

/// 一帧编码输出。
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct EncodedFrame {
    pub data: Vec<u8>,
    pub is_keyframe: bool,
    pub duration: u32,
}

/// 封装所需的轨道元数据。
struct MuxParams<'a> {
    codec: VideoCodec,
    width: u16,
    height: u16,
    timescale: u32,
    vps: Option<&'a [u8]>,
    sps: &'a [u8],
    pps: &'a [u8],
}

/// 平台 encoder 编码循环结束后的唯一收尾入口：校验帧 → mux → 组装 [`VideoResult`]。
pub(crate) fn finalize_to_mp4(
    output_path: &str,
    codec: VideoCodec,
    width: u32,
    height: u32,
    backend: &str,
    frames: &[EncodedFrame],
    vps: &[u8],
    sps: &[u8],
    pps: &[u8],
) -> Result<VideoResult, MediaError> {
    if frames.is_empty() {
        return Err(MediaError::Encode(format!("{backend} 未产出编码帧")));
    }

    let params = MuxParams {
        codec,
        width: width as u16,
        height: height as u16,
        timescale: TIMESCALE,
        vps: if vps.is_empty() { None } else { Some(vps) },
        sps,
        pps,
    };
    let size = mux_to_mp4(output_path, &params, frames)?;

    Ok(VideoResult {
        output_path: output_path.to_string(),
        size_bytes: size,
        backend: backend.to_string(),
        width,
        height,
    })
}

fn mux_to_mp4(
    output_path: &str,
    params: &MuxParams,
    frames: &[EncodedFrame],
) -> Result<u64, MediaError> {
    debug_assert!(!frames.is_empty());

    let (major_brand, compatible) = match params.codec {
        VideoCodec::H264 => ("isom", vec!["isom", "iso2", "avc1", "mp41"]),
        VideoCodec::H265 => ("isom", vec!["isom", "iso2", "hvc1", "mp41"]),
    };

    let output_path = prepare_output_path(output_path)?;
    let file = File::create(&output_path)?;
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

    let mut current_time: u64 = 0;
    for f in frames {
        let avcc = annex_b_to_avcc(&f.data)?;
        let sample = mp4::Mp4Sample {
            start_time: current_time,
            duration: f.duration,
            rendering_offset: 0,
            is_sync: f.is_keyframe,
            bytes: bytes::Bytes::from(avcc),
        };
        mp4_writer
            .write_sample(1, &sample)
            .map_err(|e| MediaError::Mux(e.to_string()))?;
        current_time += u64::from(f.duration);
    }

    mp4_writer
        .write_end()
        .map_err(|e| MediaError::Mux(e.to_string()))?;

    if params.codec == VideoCodec::H265 {
        let vps = params.vps.unwrap_or(params.sps);
        patch_hvcc_in_mp4(&output_path, vps, params.sps, params.pps)?;
    }

    let meta = std::fs::metadata(&output_path)?;
    Ok(meta.len())
}

#[allow(dead_code)]
fn _assert_seekable<W: Write + Seek>(_w: &Mp4Writer<W>) {}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::*;
    use crate::api::traits::VideoCodec;

    fn temp_mp4(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("xue_finalize_{name}_{}.mp4", std::process::id()))
    }

    fn annex_b_has_idr_nal(annex_b: &[u8]) -> bool {
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

    #[test]
    fn empty_frames_reports_backend() {
        let err = finalize_to_mp4(
            "/tmp/unused.mp4",
            VideoCodec::H264,
            640,
            480,
            "TestBackend",
            &[],
            &[],
            &[0, 0, 0, 1, 0x67, 0x01],
            &[0, 0, 0, 1, 0x68, 0x02],
        )
        .unwrap_err();
        match err {
            MediaError::Encode(msg) => assert!(msg.contains("TestBackend")),
            other => panic!("expected Encode, got {other:?}"),
        }
    }

    #[test]
    fn finalize_h264_writes_file() {
        let path = temp_mp4("h264");
        let _ = fs::remove_file(&path);
        let sps = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f];
        let pps = [0u8, 0, 0, 1, 0x68, 0xce];
        let frame = EncodedFrame {
            data: vec![0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00],
            is_keyframe: true,
            duration: 3_000,
        };
        let result = finalize_to_mp4(
            path.to_str().unwrap(),
            VideoCodec::H264,
            640,
            480,
            "TestBackend",
            &[frame],
            &[],
            &sps,
            &pps,
        )
        .unwrap();
        assert!(result.size_bytes > 0);
        assert_eq!(result.backend, "TestBackend");
        assert_eq!(result.width, 640);
        assert_eq!(result.height, 480);
        assert!(path.exists());
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn finalize_h264_accumulates_sample_start_times() {
        use mp4::TrackType;

        let path = temp_mp4("h264_timestamps");
        let _ = fs::remove_file(&path);
        let sps = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f];
        let pps = [0u8, 0, 0, 1, 0x68, 0xce];
        let frames = [
            EncodedFrame {
                data: vec![0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00],
                is_keyframe: true,
                duration: 3_000,
            },
            EncodedFrame {
                data: vec![0, 0, 0, 1, 0x41, 0x9a, 0x24, 0x00],
                is_keyframe: false,
                duration: 3_000,
            },
            EncodedFrame {
                data: vec![0, 0, 0, 1, 0x41, 0x9a, 0x28, 0x00],
                is_keyframe: false,
                duration: 3_000,
            },
        ];
        finalize_to_mp4(
            path.to_str().unwrap(),
            VideoCodec::H264,
            640,
            480,
            "TestBackend",
            &frames,
            &[],
            &sps,
            &pps,
        )
        .unwrap();

        let file = fs::File::open(&path).unwrap();
        let file_size = fs::metadata(&path).unwrap().len();
        let mut reader =
            mp4::Mp4Reader::read_header(std::io::BufReader::new(file), file_size).unwrap();
        let track_id = reader
            .tracks()
            .values()
            .find(|t| t.track_type().ok() == Some(TrackType::Video))
            .unwrap()
            .track_id();
        let mut start_times = Vec::new();
        for sample_id in 1..=3 {
            let sample = reader.read_sample(track_id, sample_id).unwrap().unwrap();
            start_times.push(sample.start_time);
        }
        assert_eq!(start_times, vec![0, 3_000, 6_000]);
        let _ = fs::remove_file(&path);
    }

    /// 生成 integration test 用 MP4 fixture：`XUE_WRITE_FIXTURE=1 cargo test write_integration_fixture -- --ignored`
    #[test]
    #[ignore]
    fn write_integration_fixture() {
        if std::env::var("XUE_WRITE_FIXTURE").ok().as_deref() != Some("1") {
            return;
        }
        use openh264::encoder::Encoder;
        use openh264::formats::{RgbSliceU8, YUVBuffer};

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../example/integration_test/fixtures/sample.mp4");
        if let Some(parent) = fixture.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let _ = fs::remove_file(&fixture);

        let w = 64usize;
        let h = 64usize;
        let rgb = vec![128u8; w * h * 3];
        let yuv = YUVBuffer::from_rgb_source(RgbSliceU8::new(&rgb, (w, h)));
        let mut encoder = Encoder::new().unwrap();

        let mut frames = Vec::new();
        let mut sps = Vec::new();
        let mut pps = Vec::new();
        for _ in 0..3 {
            let bitstream = encoder.encode(&yuv).unwrap();
            let annex_b = bitstream.to_vec();
            if sps.is_empty() {
                let (_, s, p) = crate::video_bitstream::extract_param_sets_for_codec(
                    VideoCodec::H264,
                    &annex_b,
                );
                sps = s;
                pps = p;
            }
            let is_keyframe = annex_b_has_idr_nal(&annex_b);
            frames.push(EncodedFrame {
                data: annex_b,
                is_keyframe,
                duration: 3_000,
            });
        }

        finalize_to_mp4(
            fixture.to_str().unwrap(),
            VideoCodec::H264,
            w as u32,
            h as u32,
            "TestBackend",
            &frames,
            &[],
            &sps,
            &pps,
        )
        .unwrap();
        assert!(fixture.exists());
    }
}

//! Linux 端视频硬编：OpenH264 软解 + VA-API 硬编。

mod demux;
mod vaapi;

use std::fs::File;
use std::io::BufReader;

use mp4::{Mp4Reader, TrackType};

use crate::api::traits::{MediaError, VideoCodec, VideoOptions, VideoResult};
use crate::video_encode::{finalize_encoded, plan_encode};
use crate::video_input::VideoInput;
use crate::video_mp4::read_mp4_video_metadata;

use demux::{detect_input_codec_from_reader, stream_decode_and_encode};
use vaapi::{VaapiH264Encoder, VaapiHevcEncoder};

/// demux/decode 与 VA-API encode 之间的内部接缝。
pub(super) trait Nv12EncoderSink {
    fn encode_frame(&mut self, nv12: &[u8], frame_index: usize) -> Result<(), MediaError>;
    fn frame_count(&self) -> usize;
}

pub(crate) fn backend_name() -> &'static str {
    "VA-API"
}

pub(crate) fn compress_video(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    encode_with_vaapi(input, output_path, opts)
}

pub(crate) fn probe_dimensions(input: &VideoInput) -> Result<(u32, u32, u32), MediaError> {
    let path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Linux 视频元数据仅支持本地文件路径".into()))?;
    read_mp4_video_metadata(path)
}

fn encode_with_vaapi(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let input_path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Linux 视频编码仅支持本地文件路径".into()))?;
    let plan = plan_encode(input, opts)?;

    let file_size = std::fs::metadata(input_path)?.len();
    let file = File::open(input_path)?;
    let mut reader = BufReader::new(file);
    let mut mp4 = Mp4Reader::read_header(&mut reader, file_size)
        .map_err(|e| MediaError::Decode(e.to_string()))?;

    let input_codec = detect_input_codec_from_reader(&mp4)?;
    if input_codec == demux::InputCodec::H265 {
        eprintln!("xue_hua_media_compression: HEVC 输入转码为实验性功能（VA-API VLD 软解）");
    }
    let (track_id, track_src_w, track_src_h) = mp4
        .tracks()
        .iter()
        .find(|(_, t)| t.track_type().ok() == Some(TrackType::Video))
        .map(|(id, t)| (*id, t.width() as u32, t.height() as u32))
        .ok_or_else(|| MediaError::Decode("无视频轨".into()))?;

    let sample_count = mp4
        .sample_count(track_id)
        .map_err(|e| MediaError::Decode(e.to_string()))?;

    let (frames, vps, sps, pps) = match opts.codec {
        VideoCodec::H264 => {
            let mut encoder = VaapiH264Encoder::open(
                plan.out_w,
                plan.out_h,
                plan.fps,
                opts,
                plan.frame_duration,
            )?;
            stream_decode_and_encode(
                &mut mp4,
                track_id,
                sample_count,
                input_codec,
                plan.out_w,
                plan.out_h,
                track_src_w,
                track_src_h,
                &mut encoder,
            )?;
            encoder.finish()
        }
        VideoCodec::H265 => {
            let mut encoder = VaapiHevcEncoder::open(
                plan.out_w,
                plan.out_h,
                plan.fps,
                opts,
                plan.frame_duration,
            )?;
            stream_decode_and_encode(
                &mut mp4,
                track_id,
                sample_count,
                input_codec,
                plan.out_w,
                plan.out_h,
                track_src_w,
                track_src_h,
                &mut encoder,
            )?;
            encoder.finish()
        }
    };

    finalize_encoded(
        output_path,
        opts,
        &plan,
        backend_name(),
        &frames,
        &vps,
        &sps,
        &pps,
    )
}

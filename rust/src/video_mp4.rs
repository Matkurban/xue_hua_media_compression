//! MP4 容器 metadata 读取（本地文件路径）。

use crate::api::traits::MediaError;

/// 从 mp4 容器读取视频轨元数据（全平台可用）。
pub(crate) fn read_mp4_video_metadata(path: &str) -> Result<(u32, u32, u32), MediaError> {
    use mp4::{Mp4Reader, TrackType};
    use std::fs::File;
    use std::io::BufReader;

    let file_size = std::fs::metadata(path)?.len();
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mp4 =
        Mp4Reader::read_header(reader, file_size).map_err(|e| MediaError::Decode(e.to_string()))?;

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
    use crate::api::traits::VideoCodec;
    use crate::video::{finalize_to_mp4, EncodedFrame};
    use std::path::PathBuf;

    fn temp_mp4(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("xue_mp4_meta_{name}_{}.mp4", std::process::id()))
    }

    #[test]
    fn read_metadata_from_muxed_h264() {
        let path = temp_mp4("meta");
        let _ = std::fs::remove_file(&path);
        let sps = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f];
        let pps = [0u8, 0, 0, 1, 0x68, 0xce];
        let frame = EncodedFrame {
            data: vec![0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00],
            is_keyframe: true,
            duration: 3_000,
        };
        finalize_to_mp4(
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

        let (w, h, fps) = read_mp4_video_metadata(path.to_str().unwrap()).unwrap();
        assert_eq!(w, 640);
        assert_eq!(h, 480);
        assert!(fps >= 1);
        let _ = std::fs::remove_file(path);
    }
}

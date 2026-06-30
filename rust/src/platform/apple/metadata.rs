//! 视频尺寸探测：MP4 元数据优先，AVFoundation 兜底。

use objc2::AnyThread;
use objc2_av_foundation::AVURLAsset;
use objc2_foundation::{NSString, NSURL};

use crate::api::traits::MediaError;
use crate::video_input::VideoInput;
use crate::video_mp4::read_mp4_video_metadata;

use super::reader::av_media_type_video;

fn read_source_dimensions(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    read_mp4_video_metadata(input_path).or_else(|_| read_source_dimensions_avfoundation(input_path))
}

pub(crate) fn probe_dimensions(input: &VideoInput) -> Result<(u32, u32, u32), MediaError> {
    let path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Apple 视频元数据仅支持本地文件路径".into()))?;
    read_source_dimensions(path)
}

fn read_source_dimensions_avfoundation(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    let media_type = av_media_type_video()?;
    let path = NSString::from_str(input_path);
    let url = unsafe { NSURL::fileURLWithPath(&path) };
    let asset = unsafe { AVURLAsset::initWithURL_options(AVURLAsset::alloc(), &url, None) };
    let tracks = unsafe { asset.tracksWithMediaType(&media_type) };
    if tracks.count() == 0 {
        return Err(MediaError::Decode("未找到视频轨".into()));
    }
    let track = unsafe { tracks.objectAtIndex(0) };
    let size = unsafe { track.naturalSize() };
    let fps = unsafe { track.nominalFrameRate() };
    Ok((
        size.width.abs() as u32 & !1,
        size.height.abs() as u32 & !1,
        if fps > 0.0 { fps.round() as u32 } else { 30 }.max(1),
    ))
}

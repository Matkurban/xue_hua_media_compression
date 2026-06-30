//! AVAssetReader 解码 seam：本地 MP4 → NV12 CVPixelBuffer。

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AnyThread;
use objc2_av_foundation::{AVAssetReader, AVAssetReaderTrackOutput, AVMediaTypeVideo, AVURLAsset};
use objc2_core_foundation::CFString as Objc2CfString;
use objc2_core_video::{
    kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey,
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
};
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSURL};

use crate::api::traits::MediaError;

pub(super) fn av_media_type_video() -> Result<&'static NSString, MediaError> {
    unsafe {
        AVMediaTypeVideo.ok_or_else(|| MediaError::Decode("AVMediaTypeVideo 不可用".into()))
    }
}

/// CoreVideo 的 `kCVPixelBuffer*Key` 与 `NSString` toll-free bridged，可直接作 NSDictionary 键。
unsafe fn cf_pixel_buffer_key(key: &'static Objc2CfString) -> &'static NSString {
    &*(key as *const Objc2CfString as *const NSString)
}

pub(super) fn open_video_reader(
    input_path: &str,
    out_w: u32,
    out_h: u32,
) -> Result<(Retained<AVAssetReader>, Retained<AVAssetReaderTrackOutput>), MediaError> {
    let media_type = av_media_type_video()?;
    let path = NSString::from_str(input_path);
    let url = unsafe { NSURL::fileURLWithPath(&path) };
    let asset = unsafe { AVURLAsset::initWithURL_options(AVURLAsset::alloc(), &url, None) };
    let reader = unsafe {
        AVAssetReader::assetReaderWithAsset_error(&asset)
            .map_err(|e| MediaError::Decode(format!("AVAssetReader 创建失败: {e:?}")))?
    };
    let tracks = unsafe { asset.tracksWithMediaType(&media_type) };
    if tracks.count() == 0 {
        return Err(MediaError::Decode("未找到视频轨".into()));
    }
    let track = unsafe { tracks.objectAtIndex(0) };

    let pf_key = unsafe { cf_pixel_buffer_key(kCVPixelBufferPixelFormatTypeKey) };
    let w_key = unsafe { cf_pixel_buffer_key(kCVPixelBufferWidthKey) };
    let h_key = unsafe { cf_pixel_buffer_key(kCVPixelBufferHeightKey) };
    let nv12 = NSNumber::new_i32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as i32);
    let w_num = NSNumber::new_i32(out_w as i32);
    let h_num = NSNumber::new_i32(out_h as i32);
    let dict = unsafe {
        NSDictionary::from_slices(
            &[pf_key, w_key, h_key],
            &[
                &*(&*nv12 as *const NSNumber as *const AnyObject),
                &*(&*w_num as *const NSNumber as *const AnyObject),
                &*(&*h_num as *const NSNumber as *const AnyObject),
            ],
        )
    };

    let output = unsafe {
        AVAssetReaderTrackOutput::initWithTrack_outputSettings(
            AVAssetReaderTrackOutput::alloc(),
            &track,
            Some(&dict),
        )
    };
    unsafe {
        reader.addOutput(&output);
    }

    Ok((reader, output))
}

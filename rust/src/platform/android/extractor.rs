//! AMediaExtractor 打开与尺寸探测。

use std::ffi::{c_char, CString};
use std::fs::File;
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::ptr::null_mut;

use crate::api::traits::MediaError;
use crate::video_input::VideoInput;
use crate::video_mp4::read_mp4_video_metadata;

use super::ndk::*;

fn file_open_diagnostics(input_path: &str) -> String {
    match std::fs::metadata(input_path) {
        Ok(meta) => {
            let size = meta.len();
            let mut header = [0u8; 8];
            if let Ok(mut file) = File::open(input_path) {
                let _ = file.read(&mut header);
            }
            let hex = header
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("size={size} bytes, header={hex}")
        }
        Err(e) => format!("metadata error: {e}"),
    }
}

fn try_set_data_source_fd(extractor: RawPtr, input_path: &str) -> Result<(), String> {
    let file = File::open(input_path).map_err(|e| format!("File::open: {e}"))?;
    let len = file.metadata().map_err(|e| format!("metadata: {e}"))?.len() as i64;
    let fd = file.as_raw_fd();
    try_set_data_source_fd_raw(extractor, fd, len)
}

fn try_set_data_source_fd_raw(extractor: RawPtr, fd: i32, len: i64) -> Result<(), String> {
    unsafe {
        if AMediaExtractor_setDataSourceFd(extractor, fd, 0, len) != AMEDIA_OK {
            return Err("AMediaExtractor_setDataSourceFd 失败".into());
        }
    }
    Ok(())
}

fn open_extractor_fd(
    extractor: RawPtr,
    fd: i32,
    len: i64,
    label: &str,
) -> Result<RawPtr, MediaError> {
    unsafe {
        if extractor.is_null() {
            return Err(MediaError::HardwareUnavailable(
                "AMediaExtractor_new 失败".into(),
            ));
        }
        if let Err(e) = try_set_data_source_fd_raw(extractor, fd, len) {
            AMediaExtractor_delete(extractor);
            return Err(MediaError::Decode(format!(
                "无法打开视频输入 ({label}): {e}"
            )));
        }
        Ok(extractor)
    }
}

pub(super) fn open_extractor(input: &VideoInput) -> Result<RawPtr, MediaError> {
    match input {
        VideoInput::ContentUri { fd, len, uri } => {
            let extractor = unsafe { AMediaExtractor_new() };
            open_extractor_fd(extractor, *fd, *len, uri)
        }
        VideoInput::FilePath(path) => open_extractor_file_path(path),
    }
}

fn open_extractor_file_path(input_path: &str) -> Result<RawPtr, MediaError> {
    unsafe {
        let extractor = AMediaExtractor_new();
        if extractor.is_null() {
            return Err(MediaError::HardwareUnavailable(
                "AMediaExtractor_new 失败".into(),
            ));
        }
        let path = CString::new(input_path).map_err(|e| MediaError::Io(e.to_string()))?;
        if AMediaExtractor_setDataSource(extractor, path.as_ptr()) == AMEDIA_OK {
            return Ok(extractor);
        }
        match try_set_data_source_fd(extractor, input_path) {
            Ok(()) => Ok(extractor),
            Err(fd_err) => {
                AMediaExtractor_delete(extractor);
                Err(MediaError::Decode(format!(
                    "无法打开视频文件 ({input_path}): \
                     路径方式与 fd 方式均失败 ({fd_err})。{diagnostics} \
                     请确认文件为完整 MP4/MOV 且路径可读"
                )))
            }
        }
    }
}

pub(crate) fn probe_dimensions(input: &VideoInput) -> Result<(u32, u32, u32), MediaError> {
    match input {
        VideoInput::FilePath(path) => match read_mp4_video_metadata(path) {
            Ok(dims) => Ok(dims),
            Err(mp4_err) => extractor_dimensions(input, mp4_err),
        },
        VideoInput::ContentUri { .. } => {
            extractor_dimensions(input, MediaError::Decode("content URI".into()))
        }
    }
}

fn extractor_dimensions(
    input: &VideoInput,
    mp4_err: MediaError,
) -> Result<(u32, u32, u32), MediaError> {
    unsafe {
        let extractor = open_extractor(input).map_err(|ndk_err| {
            let detail = match input {
                VideoInput::FilePath(path) => {
                    let diagnostics = file_open_diagnostics(path);
                    format!(
                        "无法读取视频元数据: MP4 解析失败 ({mp4_err}); \
                         NDK 打开失败 ({ndk_err})。{diagnostics}"
                    )
                }
                VideoInput::ContentUri { uri, .. } => format!(
                    "无法读取 content URI 元数据 ({uri}): MP4 解析失败 ({mp4_err}); \
                     NDK 打开失败 ({ndk_err})"
                ),
            };
            MediaError::Decode(detail)
        })?;
        let count = AMediaExtractor_getTrackCount(extractor);
        for i in 0..count {
            let fmt = AMediaExtractor_getTrackFormat(extractor, i);
            let mut mime_ptr: *mut c_char = null_mut();
            if AMediaFormat_getString(fmt, CString::new("mime").unwrap().as_ptr(), &mut mime_ptr) {
                let mime = c_ptr_to_string(mime_ptr);
                if mime.starts_with("video/") {
                    let mut w = 0i32;
                    let mut h = 0i32;
                    let mut fps = 30i32;
                    AMediaFormat_getInt32(fmt, CString::new("width").unwrap().as_ptr(), &mut w);
                    AMediaFormat_getInt32(fmt, CString::new("height").unwrap().as_ptr(), &mut h);
                    AMediaFormat_getInt32(
                        fmt,
                        CString::new("frame-rate").unwrap().as_ptr(),
                        &mut fps,
                    );
                    AMediaFormat_delete(fmt);
                    AMediaExtractor_delete(extractor);
                    return Ok((w as u32, h as u32, fps.max(1) as u32));
                }
            }
            AMediaFormat_delete(fmt);
        }
        AMediaExtractor_delete(extractor);
        Err(MediaError::Decode("无视频轨".into()))
    }
}

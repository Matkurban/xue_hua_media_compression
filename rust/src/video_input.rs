//! 视频输入 seam：解析 caller 路径/URI 为 platform encoder 可消费的句柄。

use std::path::Path;

use crate::api::traits::MediaError;

/// 已解析的视频输入（Path adapter 或 Android ContentUri adapter）。
#[derive(Debug)]
pub(crate) enum VideoInput {
    FilePath(String),
    #[cfg(target_os = "android")]
    ContentUri {
        uri: String,
        fd: i32,
        len: i64,
    },
}

impl VideoInput {
    /// 从 [`crate::file_input::normalize_input_path`] 之后的字符串打开输入。
    pub(crate) fn open(normalized: &str) -> Result<Self, MediaError> {
        if normalized.starts_with("content://") {
            #[cfg(target_os = "android")]
            {
                let (fd, len) = crate::platform::android_file::open_content_uri_fd(normalized)?;
                return Ok(Self::ContentUri {
                    uri: normalized.to_string(),
                    fd,
                    len,
                });
            }
            #[cfg(not(target_os = "android"))]
            {
                return Err(MediaError::Io("content:// URI 仅 Android 支持".into()));
            }
        }

        if !Path::new(normalized).exists() {
            return Err(MediaError::Decode(format!(
                "无法打开视频文件: 路径不存在 ({normalized})"
            )));
        }
        Ok(Self::FilePath(normalized.to_string()))
    }

    /// 本地文件系统路径（非 content URI）。
    pub(crate) fn file_path(&self) -> Option<&str> {
        match self {
            Self::FilePath(p) => Some(p.as_str()),
            #[cfg(target_os = "android")]
            Self::ContentUri { .. } => None,
        }
    }

    /// 探测源视频宽高与帧率（平台 adapter 在 `platform::probe_dimensions`）。
    pub(crate) fn dimensions(&self) -> Result<(u32, u32, u32), MediaError> {
        crate::platform::probe_dimensions(self)
    }
}

#[cfg(target_os = "android")]
impl Drop for VideoInput {
    fn drop(&mut self) {
        if let Self::ContentUri { fd, .. } = self {
            if *fd >= 0 {
                unsafe {
                    libc::close(*fd);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_rejects_missing_file() {
        let err = VideoInput::open("/nonexistent/xue_video_input_test.mp4").unwrap_err();
        assert!(matches!(err, MediaError::Decode(_)));
    }

    #[test]
    fn open_accepts_existing_file() {
        let path = std::env::temp_dir().join(format!("xue_video_input_{}.mp4", std::process::id()));
        std::fs::write(&path, b"").unwrap();
        let opened = VideoInput::open(path.to_str().unwrap()).unwrap();
        assert!(matches!(opened, VideoInput::FilePath(_)));
        let _ = std::fs::remove_file(path);
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn open_rejects_content_uri_off_android() {
        let err = VideoInput::open("content://media/external/video/media/1").unwrap_err();
        assert!(matches!(err, MediaError::Io(_)));
    }

    #[test]
    fn dimensions_invalid_mp4_returns_decode_error() {
        let path = std::env::temp_dir().join(format!("xue_video_dims_{}.mp4", std::process::id()));
        std::fs::write(&path, b"not a valid mp4").unwrap();
        let input = VideoInput::FilePath(path.to_string_lossy().into_owned());
        let err = input.dimensions().unwrap_err();
        assert!(matches!(err, MediaError::Decode(_)));
        let _ = std::fs::remove_file(path);
    }
}

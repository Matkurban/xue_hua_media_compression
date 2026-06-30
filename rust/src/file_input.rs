//! 输入/输出路径规范化与可读性探测。
//!
//! picker 返回的路径可能带 `file://` 前缀；Android 上可能是 `content://` URI。
//! 各 compress 实现应通过 [`normalize_input_path`] 得到统一路径后再读取；
//! 写输出前应通过 [`prepare_output_path`] 确保父目录存在。

use crate::api::traits::MediaError;

/// 规范化 picker / 文件系统路径。
///
/// - `file://` → 平台绝对路径（含 percent-decode）
/// - `content://` → 原样保留（Android 由平台模块 JNI 打开）
/// - 其它 → trim 后原样返回
pub fn normalize_input_path(path: &str) -> Result<String, MediaError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(MediaError::Io("输入路径为空".into()));
    }

    if trimmed.starts_with("content://") {
        return Ok(trimmed.to_string());
    }

    if let Some(rest) = trimmed.strip_prefix("file://") {
        return decode_file_url_path(rest);
    }

    Ok(trimmed.to_string())
}

/// 判断 Rust 侧能否直接按路径打开输入（不读入内存）。
pub fn is_directly_readable(path: &str) -> bool {
    let Ok(normalized) = normalize_input_path(path) else {
        return false;
    };

    if normalized.starts_with("content://") {
        #[cfg(target_os = "android")]
        {
            return true;
        }
        #[cfg(not(target_os = "android"))]
        {
            return false;
        }
    }

    std::path::Path::new(&normalized).exists()
}

/// 规范化输出文件路径（不支持 `content://`）。
pub fn normalize_output_path(path: &str) -> Result<String, MediaError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(MediaError::Io("输出路径为空".into()));
    }
    if trimmed.starts_with("content://") {
        return Err(MediaError::Io(
            "输出路径不能为 content:// URI，请使用应用内可写绝对路径".into(),
        ));
    }
    if let Some(rest) = trimmed.strip_prefix("file://") {
        return decode_file_url_path(rest);
    }
    Ok(trimmed.to_string())
}

/// 规范化输出路径并确保父目录存在。
pub fn prepare_output_path(path: &str) -> Result<String, MediaError> {
    let normalized = normalize_output_path(path)?;
    if let Some(parent) = std::path::Path::new(&normalized).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| {
                MediaError::Io(format!("无法创建输出目录 ({}): {e}", parent.display()))
            })?;
        }
    }
    Ok(normalized)
}

fn decode_file_url_path(rest: &str) -> Result<String, MediaError> {
    let decoded = percent_decode(rest);

    #[cfg(windows)]
    {
        // file:///C:/path or file://C:/path
        let path = decoded.trim_start_matches('/');
        Ok(path.replace('/', "\\"))
    }

    #[cfg(not(windows))]
    {
        let path = if decoded.starts_with('/') {
            decoded
        } else {
            format!("/{decoded}")
        };
        Ok(path)
    }
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_unix_file_url() {
        let path = normalize_input_path("file:///Users/test/foo.jpg").unwrap();
        assert_eq!(path, "/Users/test/foo.jpg");
    }

    #[test]
    fn normalize_absolute_path() {
        let path = normalize_input_path("/tmp/video.mp4").unwrap();
        assert_eq!(path, "/tmp/video.mp4");
    }

    #[test]
    fn normalize_content_uri() {
        let uri = "content://media/external/video/media/123";
        let path = normalize_input_path(uri).unwrap();
        assert_eq!(path, uri);
    }

    #[test]
    fn percent_decode_space() {
        assert_eq!(
            normalize_input_path("file:///Users/test/my%20file.jpg").unwrap(),
            "/Users/test/my file.jpg"
        );
    }

    #[test]
    fn prepare_output_creates_parent_dir() {
        let dir = std::env::temp_dir().join(format!(
            "xh_test_subdir_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let out = dir.join("out.jpg");
        let out_str = out.to_string_lossy().to_string();
        let prepared = prepare_output_path(&out_str).unwrap();
        assert_eq!(prepared, out_str);
        assert!(dir.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn normalize_output_rejects_content_uri() {
        assert!(normalize_output_path("content://media/external/1").is_err());
    }
}

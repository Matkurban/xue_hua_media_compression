//! Android `content://` URI → fd，供 AMediaExtractor 流式读取（不整文件读入内存）。

use crate::api::traits::MediaError;
use jni::objects::{JObject, JValue};
use jni::{jni_sig, jni_str, Env};
use ndk_context::android_context;

impl From<jni::errors::Error> for MediaError {
    fn from(e: jni::errors::Error) -> Self {
        MediaError::Native {
            code: -1,
            msg: e.to_string(),
        }
    }
}

/// 通过 ContentResolver 打开 content URI，返回 fd 与文件长度。
pub fn open_content_uri_fd(uri: &str) -> Result<(i32, i64), MediaError> {
    let ctx = android_context();
    let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) };

    vm.attach_current_thread(|env| open_content_uri_fd_with_env(env, uri))
}

fn open_content_uri_fd_with_env(env: &mut Env<'_>, uri: &str) -> Result<(i32, i64), MediaError> {
    let ctx = android_context();
    let context = unsafe { JObject::from_raw(env, ctx.context().cast()) };

    let uri_obj = {
        let uri_class = env
            .find_class(jni_str!("android/net/Uri"))
            .map_err(|e| jni_err("find Uri", e))?;
        let uri_str = env
            .new_string(uri)
            .map_err(|e| jni_err("new_string uri", e))?;
        env.call_static_method(
            uri_class,
            jni_str!("parse"),
            jni_sig!((string: java.lang.String) -> android.net.Uri),
            &[JValue::Object(&uri_str)],
        )
        .map_err(|e| jni_err("Uri.parse", e))?
        .l()
        .map_err(|e| jni_err("Uri.parse result", e))?
    };

    let resolver = env
        .call_method(
            &context,
            jni_str!("getContentResolver"),
            jni_sig!(() -> android.content.ContentResolver),
            &[],
        )
        .map_err(|e| jni_err("getContentResolver", e))?
        .l()
        .map_err(|e| jni_err("getContentResolver result", e))?;

    let mode = env
        .new_string("r")
        .map_err(|e| jni_err("new_string mode", e))?;

    let pfd = env
        .call_method(
            &resolver,
            jni_str!("openFileDescriptor"),
            jni_sig!(
                (uri: android.net.Uri, mode: java.lang.String) -> android.os.ParcelFileDescriptor
            ),
            &[JValue::Object(&uri_obj), JValue::Object(&mode)],
        )
        .map_err(|e| jni_err("openFileDescriptor", e))?
        .l()
        .map_err(|e| jni_err("openFileDescriptor result", e))?;

    if pfd.is_null() {
        return Err(MediaError::Io(format!(
            "无法打开 content URI（openFileDescriptor 返回 null）: {uri}"
        )));
    }

    let fd = env
        .call_method(&pfd, jni_str!("getFd"), jni_sig!(() -> int), &[])
        .map_err(|e| jni_err("getFd", e))?
        .i()
        .map_err(|e| jni_err("getFd result", e))?;

    let stat_size = env
        .call_method(&pfd, jni_str!("getStatSize"), jni_sig!(() -> long), &[])
        .map_err(|e| jni_err("getStatSize", e))?
        .j()
        .map_err(|e| jni_err("getStatSize result", e))?;

    if fd < 0 {
        return Err(MediaError::Io(format!("content URI fd 无效: {uri}")));
    }

    Ok((fd, stat_size))
}

fn jni_err(step: &str, e: jni::errors::Error) -> MediaError {
    MediaError::Native {
        code: -1,
        msg: format!("Android JNI {step}: {e}"),
    }
}

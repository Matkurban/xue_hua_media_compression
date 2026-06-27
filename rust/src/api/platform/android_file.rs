//! Android `content://` URI → fd，供 AMediaExtractor 流式读取（不整文件读入内存）。

use crate::api::traits::MediaError;
use jni::objects::{JObject, JString, JValue};
use jni::JNIEnv;
use ndk_context::android_context;

/// 通过 ContentResolver 打开 content URI，返回 fd 与文件长度。
pub fn open_content_uri_fd(uri: &str) -> Result<(i32, i64), MediaError> {
    let ctx = android_context();
    let vm = unsafe {
        jni::JavaVM::from_raw(ctx.vm().cast())
            .map_err(|e| MediaError::Native {
                code: -1,
                msg: format!("JavaVM::from_raw: {e}"),
            })?
    };

    let mut env = vm
        .attach_current_thread()
        .map_err(|e| MediaError::Native {
            code: -1,
            msg: format!("attach_current_thread: {e}"),
        })?;

    open_content_uri_fd_with_env(&mut env, uri)
}

fn open_content_uri_fd_with_env(env: &mut JNIEnv, uri: &str) -> Result<(i32, i64), MediaError> {
    let ctx = android_context();
    let context = unsafe { JObject::from_raw(ctx.context().cast()) };

    let uri_obj = {
        let uri_class = env
            .find_class("android/net/Uri")
            .map_err(|e| jni_err("find Uri", e))?;
        let uri_str = env
            .new_string(uri)
            .map_err(|e| jni_err("new_string uri", e))?;
        env.call_static_method(
            uri_class,
            "parse",
            "(Ljava/lang/String;)Landroid/net/Uri;",
            &[JValue::Object(&JString::from(uri_str))],
        )
        .map_err(|e| jni_err("Uri.parse", e))?
        .l()
        .map_err(|e| jni_err("Uri.parse result", e))?
    };

    let resolver = env
        .call_method(
            &context,
            "getContentResolver",
            "()Landroid/content/ContentResolver;",
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
            "openFileDescriptor",
            "(Landroid/net/Uri;Ljava/lang/String;)Landroid/os/ParcelFileDescriptor;",
            &[JValue::Object(&uri_obj), JValue::Object(&JString::from(mode))],
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
        .call_method(&pfd, "getFd", "()I", &[])
        .map_err(|e| jni_err("getFd", e))?
        .i()
        .map_err(|e| jni_err("getFd result", e))?;

    let stat_size = env
        .call_method(&pfd, "getStatSize", "()J", &[])
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

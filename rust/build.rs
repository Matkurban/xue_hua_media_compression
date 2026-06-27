//! 平台原生多媒体库的链接配置。
//!
//! 我们不依赖 FFmpeg / GStreamer，而是直接链接各操作系统自带的硬件加速框架/动态库。
//! 这些库均为系统自带，无需随包分发，因此只做链接声明，不做编译/下载。

fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    match target_os.as_str() {
        // -------------------------------------------------------------------
        // Apple: VideoToolbox 编码栈所需的系统 Framework。
        // -------------------------------------------------------------------
        "ios" | "macos" => {
            println!("cargo:rustc-link-lib=framework=VideoToolbox");
            println!("cargo:rustc-link-lib=framework=AVFoundation");
            println!("cargo:rustc-link-lib=framework=CoreMedia");
            println!("cargo:rustc-link-lib=framework=CoreVideo");
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            // HEIC 解码用到的 libheif（系统/打包均可，视 libheif-rs 链接方式而定）。
        }

        // -------------------------------------------------------------------
        // Android: NDK 媒体库。libmediandk.so 提供 AMediaCodec/AMediaFormat。
        // -------------------------------------------------------------------
        "android" => {
            println!("cargo:rustc-link-lib=dylib=mediandk");
            println!("cargo:rustc-link-lib=dylib=android");
            println!("cargo:rustc-link-lib=dylib=log");
        }

        // -------------------------------------------------------------------
        // Linux: VA-API。libva + 具体后端（DRM）。
        // -------------------------------------------------------------------
        "linux" => {
            println!("cargo:rustc-link-lib=dylib=va");
            println!("cargo:rustc-link-lib=dylib=va-drm");
        }

        // -------------------------------------------------------------------
        // Windows: Media Foundation 相关库由 `windows` crate 通过
        // #[link] 属性自动声明（mfplat / mfreadwrite / mf / mfuuid），
        // 这里无需手动 link。
        // -------------------------------------------------------------------
        "windows" => {
            // no-op, handled by `windows` crate.
        }

        _ => {}
    }
}

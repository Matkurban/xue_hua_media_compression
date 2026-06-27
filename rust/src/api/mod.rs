//! FRB 对外 API 根模块。
//!
//! 子模块划分：
//! - `traits`   : 统一接口与共享类型（ImageCompressor / VideoCompressor / 各种 Options）。
//! - `media`    : 暴露给 flutter_rust_bridge 的扁平公共函数（init / compress_*）。
//! - `image`    : 纯 Rust 图片压缩通用实现。
//! - `video`    : MP4 封装器（把硬编裸流打包成标准 MP4）。
//! - `platform` : 各操作系统原生硬件视频编码实现，按 cfg 路由。

pub mod traits;

pub mod file_input;
pub mod image;
pub mod media;
pub mod platform;
pub mod video;
pub mod video_common;

// 保留官方脚手架自带的 demo（可按需删除）。
pub mod simple;

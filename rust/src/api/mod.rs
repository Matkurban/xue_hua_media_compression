//! FRB 对外 API 根模块（仅含 external seam）。
//!
//! - `traits` : 跨语言共享类型（Options / MediaError 等）。
//! - `media`  : 暴露给 flutter_rust_bridge 的扁平公共函数（init / compress_*）。
//!
//! 图片、视频、平台实现位于 crate 根下的 `image` / `platform` / `video` 等内部 module，
//! 物理路径与 `lib.rs` 模块名一致，不在 FRB `rust_input` 扫描范围内。

pub mod media;
pub mod traits;

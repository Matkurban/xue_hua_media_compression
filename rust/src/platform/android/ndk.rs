//! NDK Media API FFI 绑定与常量。

use std::ffi::{c_char, CStr};

pub(super) type RawPtr = *mut std::ffi::c_void;

#[repr(C)]
#[derive(Default, Clone, Copy)]
pub(super) struct BufferInfo {
    offset: i32,
    size: i32,
    presentation_time_us: i64,
    flags: i32,
}

pub(super) const AMEDIA_OK: isize = 0;
pub(super) const AMEDIACODEC_CONFIGURE_FLAG_ENCODE: u32 = 1;
pub(super) const AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG: i32 = 2;
pub(super) const AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM: i32 = 4;
pub(super) const AMEDIACODEC_BUFFER_FLAG_KEY_FRAME: i32 = 1;
pub(super) const AMEDIACODEC_INFO_TRY_AGAIN_LATER: isize = -1;
pub(super) const COLOR_FORMAT_YUV420_FLEXIBLE: i32 = 0x7F420888;
pub(super) const TIMEOUT_US: i64 = 10_000;

#[link(name = "mediandk")]
extern "C" {
    pub(super) fn AMediaExtractor_new() -> RawPtr;
    pub(super) fn AMediaExtractor_delete(extractor: RawPtr) -> isize;
    pub(super) fn AMediaExtractor_setDataSource(
        extractor: RawPtr,
        location: *const c_char,
    ) -> isize;
    pub(super) fn AMediaExtractor_setDataSourceFd(
        extractor: RawPtr,
        fd: i32,
        offset: i64,
        length: i64,
    ) -> isize;
    pub(super) fn AMediaExtractor_getTrackCount(extractor: RawPtr) -> usize;
    pub(super) fn AMediaExtractor_getTrackFormat(extractor: RawPtr, index: usize) -> RawPtr;
    pub(super) fn AMediaExtractor_selectTrack(extractor: RawPtr, index: usize) -> isize;
    pub(super) fn AMediaExtractor_readSampleData(
        extractor: RawPtr,
        buffer: *mut u8,
        capacity: usize,
    ) -> isize;
    pub(super) fn AMediaExtractor_getSampleTime(extractor: RawPtr) -> i64;
    pub(super) fn AMediaExtractor_advance(extractor: RawPtr) -> bool;

    pub(super) fn AMediaFormat_new() -> RawPtr;
    pub(super) fn AMediaFormat_delete(fmt: RawPtr) -> isize;
    pub(super) fn AMediaFormat_getInt32(fmt: RawPtr, name: *const c_char, out: *mut i32) -> bool;
    pub(super) fn AMediaFormat_getString(
        fmt: RawPtr,
        name: *const c_char,
        out: *mut *mut c_char,
    ) -> bool;
    pub(super) fn AMediaFormat_setInt32(fmt: RawPtr, name: *const c_char, value: i32) -> bool;
    pub(super) fn AMediaFormat_setString(
        fmt: RawPtr,
        name: *const c_char,
        value: *const c_char,
    ) -> bool;

    pub(super) fn AMediaCodec_createDecoderByType(mime: *const c_char) -> RawPtr;
    pub(super) fn AMediaCodec_createEncoderByType(mime: *const c_char) -> RawPtr;
    pub(super) fn AMediaCodec_delete(codec: RawPtr) -> isize;
    pub(super) fn AMediaCodec_configure(
        codec: RawPtr,
        fmt: RawPtr,
        surface: RawPtr,
        crypto: RawPtr,
        flags: u32,
    ) -> isize;
    pub(super) fn AMediaCodec_start(codec: RawPtr) -> isize;
    pub(super) fn AMediaCodec_stop(codec: RawPtr) -> isize;
    pub(super) fn AMediaCodec_dequeueInputBuffer(codec: RawPtr, timeout_us: i64) -> isize;
    pub(super) fn AMediaCodec_getInputBuffer(
        codec: RawPtr,
        index: usize,
        out_size: *mut usize,
    ) -> *mut u8;
    pub(super) fn AMediaCodec_queueInputBuffer(
        codec: RawPtr,
        index: usize,
        offset: usize,
        size: usize,
        time_us: u64,
        flags: u32,
    ) -> isize;
    pub(super) fn AMediaCodec_dequeueOutputBuffer(
        codec: RawPtr,
        info: *mut BufferInfo,
        timeout_us: i64,
    ) -> isize;
    pub(super) fn AMediaCodec_getOutputBuffer(
        codec: RawPtr,
        index: usize,
        out_size: *mut usize,
    ) -> *mut u8;
    pub(super) fn AMediaCodec_releaseOutputBuffer(
        codec: RawPtr,
        index: usize,
        render: bool,
    ) -> isize;
}

pub(super) unsafe fn c_ptr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

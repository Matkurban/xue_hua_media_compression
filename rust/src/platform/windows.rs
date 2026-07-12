//! Windows 视频编码：IMFSourceReader 解码 + IMFSinkWriter 编码封装。
//!
//! 不直接驱动异步硬件 MFT（ProcessInput/ProcessOutput），避免
//! MF_E_TRANSFORM_ASYNC_LOCKED / E_UNEXPECTED 等问题；SinkWriter 内部正确处理
//! 软硬编与异步模型。

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::{addr_of_mut, null_mut};

use windows::core::{GUID, PCWSTR};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize,
};

use crate::api::traits::{MediaError, VideoCodec, VideoOptions, VideoResult};
use crate::video_encode::plan_encode;
use crate::video_input::VideoInput;
use crate::video_mp4::read_mp4_video_metadata;
use crate::video_scale::scale_nv12;

pub(crate) fn backend_name() -> &'static str {
    "MediaFoundation"
}

pub(crate) fn compress_video(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    unsafe { encode_with_media_foundation(input, output_path, opts) }
}

unsafe fn encode_with_media_foundation(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        MFStartup(MF_VERSION, MFSTARTUP_FULL).map_err(|e| {
            MediaError::Encode(format!("MFStartup: {e}"))
        })?;

        let result = encode_inner(input, output_path, opts);

        let _ = MFShutdown();
        CoUninitialize();
        result
    }
}

unsafe fn encode_inner(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    unsafe {
        let input_path = input
            .file_path()
            .ok_or_else(|| MediaError::Decode("Windows 视频编码仅支持本地文件路径".into()))?;
        let plan = plan_encode(input, opts)?;

        if let Some(parent) = Path::new(output_path).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| MediaError::Io(e.to_string()))?;
            }
        }

        let reader = create_source_reader(input_path)?;
        let (writer, stream_index) = create_sink_writer(
            output_path,
            opts.codec,
            plan.out_w,
            plan.out_h,
            plan.fps,
            opts.bitrate,
        )?;

        let frame_duration_hns = (10_000_000u64 / plan.fps.max(1) as u64) as i64;
        let mut frame_index: u64 = 0;
        let mut stream_index_out: u32 = 0;
        let mut flags = 0u32;
        let needs_scale = plan.out_w != plan.src_w || plan.out_h != plan.src_h;

        loop {
            let mut sample: Option<IMFSample> = None;
            if reader
                .ReadSample(
                    MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                    0,
                    Some(addr_of_mut!(stream_index_out)),
                    Some(addr_of_mut!(flags)),
                    None,
                    Some(addr_of_mut!(sample)),
                )
                .is_err()
            {
                break;
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                break;
            }
            let Some(sample) = sample else { break };
            if flags & MF_SOURCE_READERF_STREAMTICK.0 as u32 != 0 {
                continue;
            }

            let time = sample
                .GetSampleTime()
                .unwrap_or(frame_index as i64 * frame_duration_hns);
            let duration = sample
                .GetSampleDuration()
                .unwrap_or(frame_duration_hns)
                .max(1);

            let out_sample = if needs_scale {
                let nv12 = sample_bytes(&sample)?;
                let scaled = scale_nv12(&nv12, plan.src_w, plan.src_h, plan.out_w, plan.out_h);
                create_nv12_sample(&scaled, time, duration)?
            } else {
                // 确保时间戳完整，便于 SinkWriter 封装。
                let _ = sample.SetSampleTime(time);
                let _ = sample.SetSampleDuration(duration);
                sample
            };

            writer
                .WriteSample(stream_index, &out_sample)
                .map_err(|e| MediaError::Encode(format!("WriteSample: {e}")))?;
            frame_index += 1;
        }

        if frame_index == 0 {
            return Err(MediaError::Encode("未读到任何视频帧".into()));
        }

        writer
            .Finalize()
            .map_err(|e| MediaError::Encode(format!("SinkWriter Finalize: {e}")))?;

        let size_bytes = std::fs::metadata(output_path)
            .map(|m| m.len())
            .map_err(|e| MediaError::Io(e.to_string()))?;
        if size_bytes == 0 {
            return Err(MediaError::Encode("输出文件为空".into()));
        }

        Ok(VideoResult {
            output_path: output_path.to_string(),
            size_bytes,
            backend: backend_name().to_string(),
            width: plan.out_w,
            height: plan.out_h,
        })
    }
}

unsafe fn create_source_reader(input_path: &str) -> Result<IMFSourceReader, MediaError> {
    unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2).map_err(|e| {
            MediaError::Decode(format!("MFCreateAttributes: {e}"))
        })?;
        let attrs = attrs.ok_or_else(|| MediaError::Decode("MFCreateAttributes returned null".into()))?;
        attrs
            .SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)
            .map_err(|e| MediaError::Decode(e.to_string()))?;

        let wide = to_wide(input_path);
        let reader: IMFSourceReader =
            MFCreateSourceReaderFromURL(PCWSTR(wide.as_ptr()), &attrs)
                .map_err(|e| MediaError::Decode(format!("MFCreateSourceReaderFromURL: {e}")))?;

        reader
            .SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        reader
            .SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32, true)
            .map_err(|e| MediaError::Decode(e.to_string()))?;

        let out_type: IMFMediaType =
            MFCreateMediaType().map_err(|e| MediaError::Decode(e.to_string()))?;
        out_type
            .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        out_type
            .SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        reader
            .SetCurrentMediaType(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                None,
                &out_type,
            )
            .map_err(|e| MediaError::Decode(format!("SetCurrentMediaType NV12: {e}")))?;
        Ok(reader)
    }
}

unsafe fn create_sink_writer(
    output_path: &str,
    codec: VideoCodec,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
) -> Result<(IMFSinkWriter, u32), MediaError> {
    unsafe {
        let mut attrs: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attrs, 2).map_err(|e| {
            MediaError::Encode(format!("MFCreateAttributes: {e}"))
        })?;
        let attrs = attrs.ok_or_else(|| MediaError::Encode("MFCreateAttributes returned null".into()))?;
        // 允许 SinkWriter 选用硬件编码器；异步细节由其内部处理。
        attrs
            .SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        attrs
            .SetUINT32(&MF_SINK_WRITER_DISABLE_THROTTLING, 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;

        let wide = to_wide(output_path);
        let writer: IMFSinkWriter =
            MFCreateSinkWriterFromURL(PCWSTR(wide.as_ptr()), None, &attrs).map_err(|e| {
                MediaError::Encode(format!("MFCreateSinkWriterFromURL: {e}"))
            })?;

        let subtype = match codec {
            VideoCodec::H264 => MFVideoFormat_H264,
            VideoCodec::H265 => MFVideoFormat_HEVC,
        };
        let profile = match codec {
            VideoCodec::H264 => eAVEncH264VProfile_Base.0 as u32,
            VideoCodec::H265 => eAVEncH265VProfile_Main_420_8.0 as u32,
        };

        let out_type: IMFMediaType =
            MFCreateMediaType().map_err(|e| MediaError::Encode(e.to_string()))?;
        out_type
            .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        out_type
            .SetGUID(&MF_MT_SUBTYPE, &subtype)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        out_type
            .SetUINT32(&MF_MT_AVG_BITRATE, bitrate.max(1))
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_size(&out_type, &MF_MT_FRAME_SIZE, width, height)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_ratio(&out_type, &MF_MT_FRAME_RATE, fps.max(1), 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        out_type
            .SetUINT32(
                &MF_MT_INTERLACE_MODE,
                MFVideoInterlace_Progressive.0 as u32,
            )
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        out_type
            .SetUINT32(&MF_MT_MPEG2_PROFILE, profile)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_ratio(&out_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;

        let stream_index = writer
            .AddStream(&out_type)
            .map_err(|e| MediaError::Encode(format!("AddStream: {e}")))?;

        let in_type: IMFMediaType =
            MFCreateMediaType().map_err(|e| MediaError::Encode(e.to_string()))?;
        in_type
            .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        in_type
            .SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_size(&in_type, &MF_MT_FRAME_SIZE, width, height)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_ratio(&in_type, &MF_MT_FRAME_RATE, fps.max(1), 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        in_type
            .SetUINT32(
                &MF_MT_INTERLACE_MODE,
                MFVideoInterlace_Progressive.0 as u32,
            )
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        mf_set_attribute_ratio(&in_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)
            .map_err(|e| MediaError::Encode(e.to_string()))?;

        writer
            .SetInputMediaType(stream_index, &in_type, None)
            .map_err(|e| MediaError::Encode(format!("SetInputMediaType: {e}")))?;
        writer
            .BeginWriting()
            .map_err(|e| MediaError::Encode(format!("BeginWriting: {e}")))?;

        Ok((writer, stream_index))
    }
}

unsafe fn sample_bytes(sample: &IMFSample) -> Result<Vec<u8>, MediaError> {
    unsafe {
        let buffer: IMFMediaBuffer = sample
            .ConvertToContiguousBuffer()
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let mut ptr: *mut u8 = null_mut();
        let mut max_len = 0u32;
        let mut cur_len = 0u32;
        buffer
            .Lock(
                addr_of_mut!(ptr),
                Some(addr_of_mut!(max_len)),
                Some(addr_of_mut!(cur_len)),
            )
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let data = std::slice::from_raw_parts(ptr, cur_len as usize).to_vec();
        let _ = buffer.Unlock();
        Ok(data)
    }
}

unsafe fn create_nv12_sample(
    nv12: &[u8],
    time: i64,
    duration: i64,
) -> Result<IMFSample, MediaError> {
    unsafe {
        let sample: IMFSample =
            MFCreateSample().map_err(|e| MediaError::Encode(e.to_string()))?;
        let buffer: IMFMediaBuffer = MFCreateMemoryBuffer(nv12.len() as u32)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        let mut ptr: *mut u8 = null_mut();
        let mut max_len = 0u32;
        let mut cur_len = 0u32;
        buffer
            .Lock(
                addr_of_mut!(ptr),
                Some(addr_of_mut!(max_len)),
                Some(addr_of_mut!(cur_len)),
            )
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        std::ptr::copy_nonoverlapping(nv12.as_ptr(), ptr, nv12.len());
        buffer
            .Unlock()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        buffer
            .SetCurrentLength(nv12.len() as u32)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        sample
            .AddBuffer(&buffer)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        sample
            .SetSampleTime(time)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        sample
            .SetSampleDuration(duration)
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        Ok(sample)
    }
}

unsafe fn mf_set_attribute_size(
    mt: &IMFMediaType,
    key: &GUID,
    width: u32,
    height: u32,
) -> windows::core::Result<()> {
    unsafe { mt.SetUINT64(key, ((width as u64) << 32) | height as u64) }
}

unsafe fn mf_set_attribute_ratio(
    mt: &IMFMediaType,
    key: &GUID,
    num: u32,
    den: u32,
) -> windows::core::Result<()> {
    unsafe { mt.SetUINT64(key, ((num as u64) << 32) | den as u64) }
}

fn read_source_dimensions(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    read_mp4_video_metadata(input_path)
}

pub(crate) fn probe_dimensions(input: &VideoInput) -> Result<(u32, u32, u32), MediaError> {
    let path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Windows 视频元数据仅支持本地文件路径".into()))?;
    read_source_dimensions(path)
}

fn to_wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

/// 不依赖输入文件的 SinkWriter 冒烟测试：写入若干合成 NV12 帧并 Finalize。
#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use crate::api::traits::{VideoCodec, VideoOptions};
    use crate::video_input::VideoInput;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_mp4(tag: &str) -> String {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis();
        std::env::temp_dir()
            .join(format!("xh_mf_{tag}_{stamp}.mp4"))
            .to_string_lossy()
            .to_string()
    }

    unsafe fn write_synthetic_mp4(
        path: &str,
        width: u32,
        height: u32,
        fps: u32,
        frames: u64,
    ) -> Result<(), MediaError> {
        unsafe {
            let (writer, stream) =
                create_sink_writer(path, VideoCodec::H264, width, height, fps, 1_000_000)?;
            let frame_bytes = (width * height * 3 / 2) as usize;
            let duration = (10_000_000u64 / fps.max(1) as u64) as i64;
            for i in 0..frames {
                let mut nv12 = vec![0u8; frame_bytes];
                let y = ((i * 17) % 255) as u8;
                nv12[..(width * height) as usize].fill(y);
                nv12[(width * height) as usize..].fill(128);
                let sample = create_nv12_sample(&nv12, i as i64 * duration, duration)?;
                writer
                    .WriteSample(stream, &sample)
                    .map_err(|e| MediaError::Encode(format!("WriteSample: {e}")))?;
            }
            writer
                .Finalize()
                .map_err(|e| MediaError::Encode(format!("Finalize: {e}")))?;
            Ok(())
        }
    }

    #[test]
    fn sink_writer_encodes_synthetic_nv12_h264() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            MFStartup(MF_VERSION, MFSTARTUP_FULL).expect("MFStartup");

            let out = temp_mp4("smoke");
            let result = write_synthetic_mp4(&out, 320, 240, 30, 15);

            let _ = MFShutdown();
            CoUninitialize();

            result.expect("synthetic H.264 encode via SinkWriter");
            let meta = std::fs::metadata(&out).expect("output exists");
            assert!(meta.len() > 1000, "output too small: {}", meta.len());
            let _ = std::fs::remove_file(&out);
        }
    }

    #[test]
    fn compress_video_roundtrip_source_reader_to_sink_writer() {
        let input = temp_mp4("in");
        let output = temp_mp4("out");

        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            MFStartup(MF_VERSION, MFSTARTUP_FULL).expect("MFStartup");
            write_synthetic_mp4(&input, 320, 240, 30, 20).expect("create input mp4");
            let _ = MFShutdown();
            CoUninitialize();
        }

        let opts = VideoOptions {
            codec: VideoCodec::H264,
            bitrate: 800_000,
            max_dimension: Some(320),
            fps: Some(30),
            keyframe_interval: Some(10),
        };
        let video = VideoInput::open(&input).expect("open input");
        let result = compress_video(&video, &output, &opts).expect("compress_video");

        assert_eq!(result.backend, "MediaFoundation");
        assert_eq!(result.width, 320);
        assert_eq!(result.height, 240);
        assert!(result.size_bytes > 1000, "compressed too small");
        assert!(std::path::Path::new(&output).exists());

        let _ = std::fs::remove_file(&input);
        let _ = std::fs::remove_file(&output);
    }

    #[test]
    fn compress_video_scales_down() {
        let input = temp_mp4("scale_in");
        let output = temp_mp4("scale_out");

        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            MFStartup(MF_VERSION, MFSTARTUP_FULL).expect("MFStartup");
            write_synthetic_mp4(&input, 640, 480, 30, 12).expect("create input mp4");
            let _ = MFShutdown();
            CoUninitialize();
        }

        let opts = VideoOptions {
            codec: VideoCodec::H264,
            bitrate: 600_000,
            max_dimension: Some(320),
            fps: Some(30),
            keyframe_interval: Some(10),
        };
        let video = VideoInput::open(&input).expect("open input");
        let result = compress_video(&video, &output, &opts).expect("compress_video scale");

        assert_eq!(result.width, 320);
        assert_eq!(result.height, 240);
        assert!(result.size_bytes > 500);
        let _ = std::fs::remove_file(&input);
        let _ = std::fs::remove_file(&output);
    }
}

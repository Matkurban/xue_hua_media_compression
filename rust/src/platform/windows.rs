//! Windows 端视频硬编：Microsoft Media Foundation (WMF)。

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::ptr::null_mut;

use windows::core::{Interface, PCWSTR, PWSTR};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use crate::api::traits::{MediaError, VideoCodec, VideoOptions, VideoResult};
use crate::video_encode::{finalize_encoded, plan_encode};
use crate::video_frame_collector::EncodedFrameCollector;
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
    let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);

    let result = encode_inner(input, output_path, opts);

    let _ = MFShutdown();
    CoUninitialize();
    result
}

unsafe fn encode_inner(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let input_path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Windows 视频编码仅支持本地文件路径".into()))?;
    let plan = plan_encode(input, opts)?;
    let reader = create_source_reader(input_path)?;
    let encoder = create_hardware_encoder(
        opts.codec,
        plan.out_w,
        plan.out_h,
        plan.fps,
        opts.bitrate,
        plan.keyframe_interval,
    )?;

    let mut collector = EncodedFrameCollector::new(opts.codec, plan.frame_duration);

    let mut stream_index: u32 = 0;
    let mut flags = 0u32;
    let mut frame_index: u64 = 0;

    loop {
        let mut sample: Option<IMFSample> = None;
        if reader
            .ReadSample(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                0,
                Some(&mut stream_index),
                Some(&mut flags),
                None,
                Some(&mut sample),
            )
            .is_err()
        {
            break;
        }
        let Some(sample) = sample else { break };
        if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            break;
        }

        let nv12 = sample_to_nv12(&sample, plan.out_w, plan.out_h, plan.src_w, plan.src_h)?;
        feed_nv12_to_encoder(
            &encoder,
            &nv12,
            plan.out_w,
            plan.out_h,
            plan.fps,
            frame_index,
        )?;
        frame_index += 1;
        drain_encoder_output(&encoder, &mut collector)?;
    }

    encoder
        .ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0)
        .map_err(|e| MediaError::Native {
            code: e.code().0,
            msg: "MFT end of stream".into(),
        })?;
    encoder
        .ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0)
        .map_err(|e| MediaError::Native {
            code: e.code().0,
            msg: "MFT drain".into(),
        })?;
    drain_encoder_output(&encoder, &mut collector)?;

    let (frames, vps, sps, pps) = collector.finish();

    finalize_encoded(
        output_path,
        opts,
        &plan,
        backend_name(),
        &frames,
        &vps,
        &sps,
        &pps,
    )
}

unsafe fn create_source_reader(input_path: &str) -> Result<IMFSourceReader, MediaError> {
    let wide = to_wide(input_path);
    let reader: IMFSourceReader = MFCreateSourceReaderFromURL(PCWSTR(wide.as_ptr()), None)
        .map_err(|e| MediaError::Decode(format!("MFCreateSourceReaderFromURL: {e}")))?;

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
        .map_err(|e| MediaError::Decode(e.to_string()))?;
    Ok(reader)
}

unsafe fn create_hardware_encoder(
    codec: VideoCodec,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
    keyframe_interval: u32,
) -> Result<IMFTransform, MediaError> {
    let subtype = match codec {
        VideoCodec::H264 => MFVideoFormat_H264,
        VideoCodec::H265 => MFVideoFormat_HEVC,
    };
    let output_info = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: subtype,
    };
    let mut activates: *mut Option<IMFActivate> = null_mut();
    let mut count = 0u32;
    MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        None,
        Some(&output_info),
        &mut activates,
        &mut count,
    )
    .map_err(|e| MediaError::HardwareUnavailable(format!("MFTEnumEx: {e}")))?;
    if count == 0 || activates.is_null() {
        return Err(MediaError::HardwareUnavailable(
            "无硬件 H.264/HEVC 编码 MFT".into(),
        ));
    }
    let activate = (*activates).as_ref().unwrap();
    let encoder: IMFTransform = activate
        .ActivateObject()
        .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;
    CoTaskMemFree(Some(activates as *const _));

    let out_type: IMFMediaType =
        MFCreateMediaType().map_err(|e| MediaError::Encode(e.to_string()))?;
    out_type
        .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    out_type
        .SetGUID(&MF_MT_SUBTYPE, &subtype)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    out_type
        .SetUINT32(&MF_MT_AVG_BITRATE, bitrate)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    MFSetAttributeSize(&out_type, &MF_MT_FRAME_SIZE, width, height)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    MFSetAttributeRatio(&out_type, &MF_MT_FRAME_RATE, fps, 1)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    out_type
        .SetUINT32(&MF_MT_MAX_KEYFRAME_SPACING, keyframe_interval)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    encoder
        .SetOutputType(0, &out_type, 0)
        .map_err(|e| MediaError::Encode(e.to_string()))?;

    let in_type: IMFMediaType =
        MFCreateMediaType().map_err(|e| MediaError::Encode(e.to_string()))?;
    in_type
        .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    in_type
        .SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    MFSetAttributeSize(&in_type, &MF_MT_FRAME_SIZE, width, height)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    MFSetAttributeRatio(&in_type, &MF_MT_FRAME_RATE, fps, 1)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    encoder
        .SetInputType(0, &in_type, 0)
        .map_err(|e| MediaError::Encode(e.to_string()))?;

    encoder
        .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    encoder
        .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    Ok(encoder)
}

unsafe fn sample_to_nv12(
    sample: &IMFSample,
    out_w: u32,
    out_h: u32,
    src_w: u32,
    src_h: u32,
) -> Result<Vec<u8>, MediaError> {
    let buffer: IMFMediaBuffer = sample
        .ConvertToContiguousBuffer()
        .map_err(|e| MediaError::Decode(e.to_string()))?;
    let mut ptr = null_mut();
    let mut max_len = 0u32;
    let mut cur_len = 0u32;
    buffer
        .Lock(&mut ptr, Some(&mut max_len), Some(&mut cur_len))
        .map_err(|e| MediaError::Decode(e.to_string()))?;
    let data = std::slice::from_raw_parts(ptr, cur_len as usize).to_vec();
    buffer.Unlock().ok();
    if out_w != src_w || out_h != src_h {
        Ok(scale_nv12(&data, src_w, src_h, out_w, out_h))
    } else {
        Ok(data)
    }
}

unsafe fn feed_nv12_to_encoder(
    encoder: &IMFTransform,
    nv12: &[u8],
    width: u32,
    height: u32,
    fps: u32,
    frame_index: u64,
) -> Result<(), MediaError> {
    let sample: IMFSample = MFCreateSample().map_err(|e| MediaError::Encode(e.to_string()))?;
    let buffer: IMFMediaBuffer =
        MFCreateMemoryBuffer(nv12.len() as u32).map_err(|e| MediaError::Encode(e.to_string()))?;
    let mut ptr = null_mut();
    let mut max_len = 0u32;
    let mut cur_len = 0u32;
    buffer
        .Lock(&mut ptr, Some(&mut max_len), Some(&mut cur_len))
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
    let frame_duration = 10_000_000u64 / fps as u64;
    sample
        .SetSampleTime((frame_index * frame_duration) as i64)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    sample
        .SetSampleDuration(frame_duration as i64)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    let _ = (width, height);
    encoder
        .ProcessInput(0, &sample, 0)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    Ok(())
}

unsafe fn drain_encoder_output(
    encoder: &IMFTransform,
    collector: &mut EncodedFrameCollector,
) -> Result<(), MediaError> {
    loop {
        let mut out_buf = MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: 0,
            pSample: std::mem::ManuallyDrop::new(None),
            dwStatus: 0,
            pEvents: std::mem::ManuallyDrop::new(None),
        };
        let mut status = 0u32;
        match encoder.ProcessOutput(0, &mut [out_buf], &mut status) {
            Ok(()) => {
                let sample = out_buf.pSample.take();
                let Some(sample) = sample else { continue };
                let is_key = sample.GetUINT32(&MFSampleExtension_CleanPoint).unwrap_or(0) == 1;
                let buffer = sample
                    .ConvertToContiguousBuffer()
                    .map_err(|e| MediaError::Encode(e.to_string()))?;
                let mut ptr = null_mut();
                let mut max_len = 0u32;
                let mut cur_len = 0u32;
                buffer
                    .Lock(&mut ptr, Some(&mut max_len), Some(&mut cur_len))
                    .map_err(|e| MediaError::Encode(e.to_string()))?;
                let nal = std::slice::from_raw_parts(ptr, cur_len as usize).to_vec();
                buffer.Unlock().ok();
                collector.push_access_unit(nal, is_key);
            }
            Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => break,
            Err(e) => {
                return Err(MediaError::Native {
                    code: e.code().0,
                    msg: format!("ProcessOutput: {e}"),
                })
            }
        }
    }
    Ok(())
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

use windows::Win32::System::Com::CoTaskMemFree;

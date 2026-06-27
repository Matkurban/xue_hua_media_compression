//! Linux 端视频硬编：OpenH264 软解 + VA-API 硬编。

use std::fs::File;
use std::io::BufReader;

use cros_libva::bindings;
use cros_libva::buffer::{
    BufferType, EncPictureParameter, EncPictureParameterBufferH264, EncPictureParameterBufferHEVC,
    EncSequenceParameter, EncSequenceParameterBufferH264, EncSequenceParameterBufferHEVC,
    EncSliceParameter, EncSliceParameterBufferH264, EncSliceParameterBufferHEVC, H264EncPicFields,
    H264EncSeqFields, H264VuiFields, HEVCEncPicFields, HEVCEncSeqFields, HevcEncPicSccFields,
    HevcEncSeqSccFields, HevcEncSliceFields, HevcEncVuiFields, HevcLongSliceFlags, HevcPicFields,
    HevcSliceParsingFields, MappedCodedBuffer, PictureH264, PictureHEVC, PictureParameter,
    PictureParameterBufferHEVC, SliceParameter, SliceParameterBufferHEVC,
};
use cros_libva::display::Display;
use cros_libva::picture::Picture;
use cros_libva::surface::UsageHint;
use cros_libva::Context;
use mp4::{Mp4Reader, TrackType};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use crate::api::traits::{MediaError, VideoCodec, VideoCompressor, VideoOptions, VideoResult};
use crate::api::video::{mux_to_mp4, EncodedFrame, MuxParams};
use crate::api::video_common::{
    avcc_to_annex_b, extract_param_sets_for_codec, read_mp4_video_metadata, scale_dims, scale_nv12,
};

/// VA-API 编码 surface 池大小（逐帧轮转，不随视频长度增长）。
const VAAPI_SURFACE_POOL: usize = 4;

#[flutter_rust_bridge::frb(opaque)]
pub(crate) struct LinuxVideoCompressor;

impl LinuxVideoCompressor {
    pub(crate) fn backend_name() -> &'static str {
        "VA-API"
    }
}

impl VideoCompressor for LinuxVideoCompressor {
    fn compress(
        input_path: &str,
        output_path: &str,
        opts: &VideoOptions,
    ) -> Result<VideoResult, MediaError> {
        encode_with_vaapi(input_path, output_path, opts)
    }
}

fn encode_with_vaapi(
    input_path: &str,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let (src_w, src_h, src_fps) = read_mp4_video_metadata(input_path)?;
    let (out_w, out_h) = scale_dims(src_w, src_h, opts.max_dimension);
    let fps = opts.fps.unwrap_or(src_fps).max(1);
    let frame_duration = 90_000 / fps;

    let file_size = std::fs::metadata(input_path)?.len();
    let file = File::open(input_path)?;
    let mut reader = BufReader::new(file);
    let mut mp4 = Mp4Reader::read_header(&mut reader, file_size)
        .map_err(|e| MediaError::Decode(e.to_string()))?;

    let input_codec = detect_input_codec_from_reader(&mp4)?;
    let (track_id, track_src_w, track_src_h) = mp4
        .tracks()
        .iter()
        .find(|(_, t)| t.track_type().ok() == Some(TrackType::Video))
        .map(|(id, t)| (*id, t.width() as u32, t.height() as u32))
        .ok_or_else(|| MediaError::Decode("无视频轨".into()))?;

    let sample_count = mp4
        .sample_count(track_id)
        .map_err(|e| MediaError::Decode(e.to_string()))?;

    let (frames, vps, sps, pps) = match opts.codec {
        VideoCodec::H264 => {
            let mut encoder =
                VaapiH264Encoder::open(out_w, out_h, fps, opts, frame_duration)?;
            stream_decode_and_encode(
                &mut mp4,
                track_id,
                sample_count,
                input_codec,
                out_w,
                out_h,
                track_src_w,
                track_src_h,
                &mut encoder,
            )?;
            encoder.finish()
        }
        VideoCodec::H265 => {
            let mut encoder =
                VaapiHevcEncoder::open(out_w, out_h, fps, opts, frame_duration)?;
            stream_decode_and_encode(
                &mut mp4,
                track_id,
                sample_count,
                input_codec,
                out_w,
                out_h,
                track_src_w,
                track_src_h,
                &mut encoder,
            )?;
            encoder.finish()
        }
    };

    if frames.is_empty() {
        return Err(MediaError::Encode("VA-API 未产出编码帧".into()));
    }

    let params = MuxParams {
        codec: opts.codec,
        width: out_w as u16,
        height: out_h as u16,
        timescale: 90_000,
        vps: if vps.is_empty() {
            None
        } else {
            Some(vps.as_slice())
        },
        sps: &sps,
        pps: &pps,
    };
    let size = mux_to_mp4(output_path, &params, &frames)?;

    Ok(VideoResult {
        output_path: output_path.to_string(),
        size_bytes: size,
        backend: LinuxVideoCompressor::backend_name().to_string(),
        width: out_w,
        height: out_h,
    })
}

trait VaapiNv12Encoder {
    fn encode_frame(&mut self, nv12: &[u8], frame_index: usize) -> Result<(), MediaError>;
    fn frame_count(&self) -> usize;
}

fn stream_decode_and_encode<E: VaapiNv12Encoder>(
    mp4: &mut Mp4Reader<BufReader<File>>,
    track_id: u32,
    sample_count: u32,
    input_codec: InputCodec,
    out_w: u32,
    out_h: u32,
    src_w: u32,
    src_h: u32,
    encoder: &mut E,
) -> Result<(), MediaError> {
    match input_codec {
        InputCodec::H264 => {
            let mut decoder = Decoder::new().map_err(|e| MediaError::Decode(e.to_string()))?;
            for sample_id in 1..=sample_count {
                let sample = mp4
                    .read_sample(track_id, sample_id)
                    .map_err(|e| MediaError::Decode(e.to_string()))?;
                let Some(sample) = sample else { break };
                let annex_b = avcc_to_annex_b(&sample.bytes);
                if let Some(yuv) = decoder
                    .decode(&annex_b)
                    .map_err(|e| MediaError::Decode(e.to_string()))?
                {
                    let (w, h) = yuv.dimensions();
                    let nv12 = i420_to_nv12(&yuv);
                    let scaled = if out_w != w as u32 || out_h != h as u32 {
                        scale_nv12(&nv12, w as u32, h as u32, out_w, out_h)
                    } else {
                        nv12
                    };
                    encoder.encode_frame(&scaled, encoder.frame_count())?;
                }
            }
        }
        InputCodec::H265 => {
            let mut decoder = HevcVldDecoder::open(src_w, src_h)?;
            for sample_id in 1..=sample_count {
                let sample = mp4
                    .read_sample(track_id, sample_id)
                    .map_err(|e| MediaError::Decode(e.to_string()))?;
                let Some(sample) = sample else { break };
                let annex_b = avcc_to_annex_b(&sample.bytes);
                let nv12 = decoder.decode_sample(&annex_b)?;
                let scaled = if out_w != src_w || out_h != src_h {
                    scale_nv12(&nv12, src_w, src_h, out_w, out_h)
                } else {
                    nv12
                };
                encoder.encode_frame(&scaled, encoder.frame_count())?;
            }
        }
    }

    if encoder.frame_count() == 0 {
        return Err(MediaError::Decode("未能解码任何视频帧".into()));
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum InputCodec {
    H264,
    H265,
}

fn detect_input_codec_from_reader(mp4: &Mp4Reader<impl std::io::Read + std::io::Seek>) -> Result<InputCodec, MediaError> {
    let track = mp4
        .tracks()
        .values()
        .find(|t| t.track_type().ok() == Some(TrackType::Video))
        .ok_or_else(|| MediaError::Decode("无视频轨".into()))?;
    let box_type = track
        .box_type()
        .map_err(|e| MediaError::Decode(e.to_string()))?;
    let fourcc = box_type.to_string();
    if fourcc.starts_with("hev") || fourcc.starts_with("hvc") {
        Ok(InputCodec::H265)
    } else {
        Ok(InputCodec::H264)
    }
}

/// OpenH264 输出 I420 平面，VA-API 需要 NV12（UV 交错）。
fn i420_to_nv12(yuv: &impl YUVSource) -> Vec<u8> {
    let (w, h) = yuv.dimensions();
    let (y_stride, uv_stride, _) = yuv.strides();
    let mut nv12 = vec![0u8; w * h * 3 / 2];
    for row in 0..h {
        let src = &yuv.y()[row * y_stride..row * y_stride + w];
        nv12[row * w..(row + 1) * w].copy_from_slice(src);
    }
    let uv_off = w * h;
    let half_h = h / 2;
    for row in 0..half_h {
        let u_row = &yuv.u()[row * uv_stride..row * uv_stride + w / 2];
        let v_row = &yuv.v()[row * uv_stride..row * uv_stride + w / 2];
        for col in 0..w / 2 {
            let dst = uv_off + row * w + col * 2;
            nv12[dst] = u_row[col];
            nv12[dst + 1] = v_row[col];
        }
    }
    nv12
}

struct VaapiH264Encoder {
    context: std::rc::Rc<Context>,
    surfaces: Vec<cros_libva::surface::Surface>,
    image_fmt: bindings::VAImageFormat,
    width: u32,
    height: u32,
    mb_w: u16,
    mb_h: u16,
    frame_duration: u32,
    keyframe_interval: usize,
    seq_pending: Option<cros_libva::buffer::Buffer>,
    encoded_frames: Vec<EncodedFrame>,
    vps: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
}

impl VaapiH264Encoder {
    fn open(
        width: u32,
        height: u32,
        fps: u32,
        opts: &VideoOptions,
        frame_duration: u32,
    ) -> Result<Self, MediaError> {
        let display = Display::open()
            .map_err(|e| MediaError::HardwareUnavailable(format!("打开 VA-API 设备失败: {e}")))?;

        let format = bindings::VA_RT_FORMAT_YUV420;
        let entrypoint = bindings::VAEntrypoint::VAEntrypointEncSliceLP;
        let profile = bindings::VAProfile::VAProfileH264ConstrainedBaseline;

        let mut attrs = vec![bindings::VAConfigAttrib {
            type_: bindings::VAConfigAttribType::VAConfigAttribRTFormat,
            value: 0,
        }];
        display
            .get_config_attributes(profile, entrypoint, &mut attrs)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let config = display
            .create_config(attrs, profile, entrypoint)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let surfaces = display
            .create_surfaces(
                format,
                None,
                width,
                height,
                Some(UsageHint::USAGE_HINT_ENCODER),
                vec![(); VAAPI_SURFACE_POOL],
            )
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let context = display
            .create_context(&config, width, height, Some(&surfaces), true)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let image_fmts = display
            .query_image_formats()
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;
        let image_fmt = image_fmts
            .into_iter()
            .find(|f| f.fourcc == bindings::VA_FOURCC_NV12)
            .ok_or_else(|| MediaError::HardwareUnavailable("无 NV12 VA 图像格式".into()))?;

        let mb_w = (width / 16).max(1) as u16;
        let mb_h = (height / 16).max(1) as u16;
        let seq_buf = create_seq_buffer(&context, mb_w, mb_h, fps, opts)?;

        Ok(Self {
            context,
            surfaces,
            image_fmt,
            width,
            height,
            mb_w,
            mb_h,
            frame_duration,
            keyframe_interval: opts.keyframe_interval.unwrap_or(60).max(1) as usize,
            seq_pending: Some(seq_buf),
            encoded_frames: Vec::new(),
            vps: Vec::new(),
            sps: Vec::new(),
            pps: Vec::new(),
        })
    }

    fn finish(self) -> (Vec<EncodedFrame>, Vec<u8>, Vec<u8>, Vec<u8>) {
        (self.encoded_frames, self.vps, self.sps, self.pps)
    }
}

impl VaapiNv12Encoder for VaapiH264Encoder {
    fn frame_count(&self) -> usize {
        self.encoded_frames.len()
    }

    fn encode_frame(&mut self, nv12: &[u8], frame_index: usize) -> Result<(), MediaError> {
        let surface_idx = frame_index % self.surfaces.len();
        let surface = self.surfaces[surface_idx].clone();
        let surface_id = surface.id();

        upload_nv12_to_surface(&surface, &self.image_fmt, self.width, self.height, nv12)?;

        let coded_buffer = self
            .context
            .create_enc_coded(nv12.len())
            .map_err(|e| MediaError::Encode(e.to_string()))?;

        let pic_buf = create_pic_buffer(&self.context, surface_id, coded_buffer.id())?;
        let slice_buf = create_slice_buffer(&self.context, self.mb_w, self.mb_h)?;

        let mut picture = Picture::new(0, std::rc::Rc::clone(&self.context), surface);
        picture.add_buffer(pic_buf);
        if frame_index == 0 {
            if let Some(seq) = self.seq_pending.take() {
                picture.add_buffer(seq);
            }
        }
        picture.add_buffer(slice_buf);

        let picture = picture
            .begin()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        let picture = picture
            .render()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        let picture = picture
            .end()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        picture
            .sync()
            .map_err(|(e, _)| MediaError::Encode(e.to_string()))?;

        let mapped =
            MappedCodedBuffer::new(&coded_buffer).map_err(|e| MediaError::Encode(e.to_string()))?;
        let mut nal = Vec::new();
        for segment in mapped.segments() {
            nal.extend_from_slice(segment.buf);
        }
        if self.sps.is_empty() {
            let (v, s, p) = extract_param_sets_for_codec(VideoCodec::H264, &nal);
            self.vps = v.unwrap_or_default();
            self.sps = s;
            self.pps = p;
        }
        let is_key = frame_index == 0 || frame_index % self.keyframe_interval == 0;
        self.encoded_frames.push(EncodedFrame {
            data: nal,
            is_keyframe: is_key,
            duration: self.frame_duration,
        });
        Ok(())
    }
}

struct VaapiHevcEncoder {
    context: std::rc::Rc<Context>,
    surfaces: Vec<cros_libva::surface::Surface>,
    image_fmt: bindings::VAImageFormat,
    width: u32,
    height: u32,
    ctu_count: u32,
    frame_duration: u32,
    gop: u32,
    seq_pending: Option<cros_libva::buffer::Buffer>,
    ref_frames: [PictureHEVC; 15],
    encoded_frames: Vec<EncodedFrame>,
    vps: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
}

impl VaapiHevcEncoder {
    fn open(
        width: u32,
        height: u32,
        fps: u32,
        opts: &VideoOptions,
        frame_duration: u32,
    ) -> Result<Self, MediaError> {
        let display = Display::open()
            .map_err(|e| MediaError::HardwareUnavailable(format!("打开 VA-API 设备失败: {e}")))?;

        let format = bindings::VA_RT_FORMAT_YUV420;
        let entrypoint = bindings::VAEntrypoint::VAEntrypointEncSliceLP;
        let profile = bindings::VAProfile::VAProfileHEVCMain;

        let mut attrs = vec![bindings::VAConfigAttrib {
            type_: bindings::VAConfigAttribType::VAConfigAttribRTFormat,
            value: 0,
        }];
        display
            .get_config_attributes(profile, entrypoint, &mut attrs)
            .map_err(|e| MediaError::HardwareUnavailable(format!("HEVC 编码不支持: {e}")))?;

        let config = display
            .create_config(attrs, profile, entrypoint)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let surfaces = display
            .create_surfaces(
                format,
                None,
                width,
                height,
                Some(UsageHint::USAGE_HINT_ENCODER),
                vec![(); VAAPI_SURFACE_POOL],
            )
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let context = display
            .create_context(&config, width, height, Some(&surfaces), true)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let image_fmts = display
            .query_image_formats()
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;
        let image_fmt = image_fmts
            .into_iter()
            .find(|f| f.fourcc == bindings::VA_FOURCC_NV12)
            .ok_or_else(|| MediaError::HardwareUnavailable("无 NV12 VA 图像格式".into()))?;

        let ctu_w = ((width + 15) / 16).max(1);
        let ctu_h = ((height + 15) / 16).max(1);
        let gop = opts.keyframe_interval.unwrap_or(60).max(1);
        let seq_buf = create_hevc_seq_buffer(&context, width, height, fps, opts, gop)?;

        Ok(Self {
            context,
            surfaces,
            image_fmt,
            width,
            height,
            ctu_count: ctu_w * ctu_h,
            frame_duration,
            gop,
            seq_pending: Some(seq_buf),
            ref_frames: invalid_hevc_ref_array(),
            encoded_frames: Vec::new(),
            vps: Vec::new(),
            sps: Vec::new(),
            pps: Vec::new(),
        })
    }

    fn finish(self) -> (Vec<EncodedFrame>, Vec<u8>, Vec<u8>, Vec<u8>) {
        (self.encoded_frames, self.vps, self.sps, self.pps)
    }
}

impl VaapiNv12Encoder for VaapiHevcEncoder {
    fn frame_count(&self) -> usize {
        self.encoded_frames.len()
    }

    fn encode_frame(&mut self, nv12: &[u8], frame_index: usize) -> Result<(), MediaError> {
        let surface_idx = frame_index % self.surfaces.len();
        let surface = self.surfaces[surface_idx].clone();
        let surface_id = surface.id();
        upload_nv12_to_surface(&surface, &self.image_fmt, self.width, self.height, nv12)?;

        let coded_buffer = self
            .context
            .create_enc_coded(nv12.len().max(4096))
            .map_err(|e| MediaError::Encode(e.to_string()))?;

        let is_idr = frame_index == 0 || frame_index as u32 % self.gop == 0;
        let pic_buf = create_hevc_pic_buffer(
            &self.context,
            surface_id,
            coded_buffer.id(),
            &self.ref_frames,
            is_idr,
        )?;
        let slice_buf = create_hevc_enc_slice_buffer(&self.context, self.ctu_count, is_idr)?;

        let mut picture = Picture::new(
            frame_index as u64,
            std::rc::Rc::clone(&self.context),
            surface,
        );
        picture.add_buffer(pic_buf);
        if frame_index == 0 {
            if let Some(seq) = self.seq_pending.take() {
                picture.add_buffer(seq);
            }
        }
        picture.add_buffer(slice_buf);

        let picture = picture
            .begin()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        let picture = picture
            .render()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        let picture = picture
            .end()
            .map_err(|e| MediaError::Encode(e.to_string()))?;
        picture
            .sync()
            .map_err(|(e, _)| MediaError::Encode(e.to_string()))?;

        let mapped =
            MappedCodedBuffer::new(&coded_buffer).map_err(|e| MediaError::Encode(e.to_string()))?;
        let mut nal = Vec::new();
        for segment in mapped.segments() {
            nal.extend_from_slice(segment.buf);
        }
        if self.sps.is_empty() {
            let (v, s, p) = extract_param_sets_for_codec(VideoCodec::H265, &nal);
            self.vps = v.unwrap_or_default();
            self.sps = s;
            self.pps = p;
        }
        self.encoded_frames.push(EncodedFrame {
            data: nal,
            is_keyframe: is_idr,
            duration: self.frame_duration,
        });
        Ok(())
    }
}

fn upload_nv12_to_surface(
    surface: &cros_libva::surface::Surface,
    image_fmt: &bindings::VAImageFormat,
    width: u32,
    height: u32,
    data: &[u8],
) -> Result<(), MediaError> {
    let mut image = cros_libva::image::Image::create_from(
        surface,
        *image_fmt,
        (width, height),
        (width, height),
    )
    .map_err(|e| MediaError::Encode(e.to_string()))?;
    let va_image = *image.image();
    let dest = image.as_mut();
    let w = width as usize;
    let h = height as usize;
    let mut src = data;
    let mut dst = &mut dest[va_image.offsets[0] as usize..];
    for _ in 0..h {
        let row = w.min(src.len());
        dst[..row].copy_from_slice(&src[..row]);
        dst = &mut dst[va_image.pitches[0] as usize..];
        src = &src[w..];
    }
    let mut src = &data[w * h..];
    let mut dst = &mut dest[va_image.offsets[1] as usize..];
    for _ in 0..h / 2 {
        let row = w.min(src.len());
        dst[..row].copy_from_slice(&src[..row]);
        dst = &mut dst[va_image.pitches[1] as usize..];
        src = &src[w..];
    }
    Ok(())
}

fn create_seq_buffer(
    context: &Context,
    mb_w: u16,
    mb_h: u16,
    fps: u32,
    opts: &VideoOptions,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let seq_fields = H264EncSeqFields::new(1, 1, 0, 0, 0, 1, 0, 2, 0);
    let sps = BufferType::EncSequenceParameter(EncSequenceParameter::H264(
        EncSequenceParameterBufferH264::new(
            0,
            10,
            10,
            fps as i32,
            1,
            0,
            1,
            mb_w,
            mb_h,
            &seq_fields,
            0,
            0,
            0,
            0,
            0,
            [0; 256],
            None,
            Some(H264VuiFields::new(1, 1, 0, 0, 0, 1, 0, 0)),
            255,
            1,
            1,
            1,
            (opts.bitrate / 1000).min(60_000) as i32,
        ),
    ));
    context
        .create_buffer(sps)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

fn create_pic_buffer(
    context: &Context,
    surface_id: bindings::VASurfaceID,
    coded_id: bindings::VABufferID,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let ref_frames: [PictureH264; 16] = std::array::from_fn(|_| {
        PictureH264::new(
            bindings::VA_INVALID_ID,
            0,
            bindings::VA_INVALID_SURFACE,
            0,
            0,
        )
    });
    let pps = BufferType::EncPictureParameter(EncPictureParameter::H264(
        EncPictureParameterBufferH264::new(
            PictureH264::new(surface_id, 0, 0, 0, 0),
            ref_frames,
            coded_id,
            0,
            0,
            0,
            0,
            26,
            0,
            0,
            0,
            0,
            &H264EncPicFields::new(1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0),
        ),
    ));
    context
        .create_buffer(pps)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

fn create_slice_buffer(
    context: &Context,
    mb_w: u16,
    mb_h: u16,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let ref_pic_list: [PictureH264; 32] = std::array::from_fn(|_| {
        PictureH264::new(
            bindings::VA_INVALID_ID,
            0,
            bindings::VA_INVALID_SURFACE,
            0,
            0,
        )
    });
    let slice =
        BufferType::EncSliceParameter(EncSliceParameter::H264(EncSliceParameterBufferH264::new(
            0,
            (mb_w as u32) * (mb_h as u32),
            bindings::VA_INVALID_ID,
            2,
            0,
            1,
            0,
            0,
            [0, 0],
            1,
            0,
            0,
            0,
            ref_pic_list,
            ref_pic_list,
            0,
            0,
            0,
            [0; 32],
            [0; 32],
            0,
            [[0; 2]; 32],
            [[0; 2]; 32],
            0,
            [0; 32],
            [0; 32],
            0,
            [[0; 2]; 32],
            [[0; 2]; 32],
            0,
            0,
            0,
            2,
            2,
        )));
    context
        .create_buffer(slice)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

struct HevcVldDecoder {
    context: std::rc::Rc<Context>,
    surfaces: Vec<cros_libva::surface::Surface>,
    image_fmt: bindings::VAImageFormat,
    width: u32,
    height: u32,
    poc: i32,
}

impl HevcVldDecoder {
    fn open(width: u32, height: u32) -> Result<Self, MediaError> {
        let display = Display::open()
            .map_err(|e| MediaError::HardwareUnavailable(format!("打开 VA-API 设备失败: {e}")))?;

        let profile = bindings::VAProfile::VAProfileHEVCMain;
        let entrypoint = bindings::VAEntrypoint::VAEntrypointVLD;
        let mut attrs = vec![bindings::VAConfigAttrib {
            type_: bindings::VAConfigAttribType::VAConfigAttribRTFormat,
            value: 0,
        }];
        display
            .get_config_attributes(profile, entrypoint, &mut attrs)
            .map_err(|_| MediaError::UnsupportedFormat("HEVC 输入需要 VA-API VLD 支持".into()))?;

        let config = display
            .create_config(attrs, profile, entrypoint)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let aligned_h = ((height + 15) / 16) * 16;
        let surfaces = display
            .create_surfaces(
                bindings::VA_RT_FORMAT_YUV420,
                None,
                width,
                aligned_h,
                Some(UsageHint::USAGE_HINT_DECODER),
                vec![(); 4],
            )
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let context = display
            .create_context(&config, width, aligned_h, Some(&surfaces), true)
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;

        let image_fmts = display
            .query_image_formats()
            .map_err(|e| MediaError::HardwareUnavailable(e.to_string()))?;
        let image_fmt = image_fmts
            .into_iter()
            .find(|f| f.fourcc == bindings::VA_FOURCC_NV12)
            .ok_or_else(|| MediaError::HardwareUnavailable("无 NV12 VA 图像格式".into()))?;

        Ok(Self {
            context,
            surfaces,
            image_fmt,
            width,
            height,
            poc: 0,
        })
    }

    fn decode_sample(&mut self, annex_b: &[u8]) -> Result<Vec<u8>, MediaError> {
        let idx = (self.poc as usize) % self.surfaces.len();
        let surface = self.surfaces[idx].clone();
        let surface_id = surface.id();
        let is_idr = is_hevc_idr_nal(annex_b);

        let curr_pic = PictureHEVC::new(surface_id, self.poc, 0);
        let ref_frames = invalid_hevc_ref_array();
        let pic_fields =
            HevcPicFields::new(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0);
        let slice_parsing = HevcSliceParsingFields::new(
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            if is_idr { 1 } else { 0 },
            if is_idr { 1 } else { 0 },
            if is_idr { 1 } else { 0 },
        );
        let pic_param = PictureParameterBufferHEVC::new(
            curr_pic,
            ref_frames,
            self.width as u16,
            self.height as u16,
            &pic_fields,
            15,
            0,
            0,
            0,
            0,
            3,
            3,
            0,
            2,
            0,
            3,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            [0; 19],
            [0; 21],
            &slice_parsing,
            4,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        );
        let long_slice =
            HevcLongSliceFlags::new(1, 0, if is_idr { 2 } else { 0 }, 0, 1, 1, 0, 0, 1, 0, 0, 1);
        let mut slice_param = SliceParameterBufferHEVC::new(
            annex_b.len() as u32,
            0,
            0,
            0,
            0,
            [[0xFF; 15]; 2],
            &long_slice,
            0xFF,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            [0; 15],
            [0; 15],
            [[0; 2]; 15],
            [[0; 2]; 15],
            [0; 15],
            [0; 15],
            [[0; 2]; 15],
            [[0; 2]; 15],
            0,
            0,
            0,
            0,
        );
        slice_param.set_as_last();

        let pic_buf = self
            .context
            .create_buffer(BufferType::PictureParameter(PictureParameter::HEVC(
                pic_param,
            )))
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let slice_buf = self
            .context
            .create_buffer(BufferType::SliceParameter(SliceParameter::HEVC(
                slice_param,
            )))
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let data_buf = self
            .context
            .create_buffer(BufferType::SliceData(annex_b.to_vec()))
            .map_err(|e| MediaError::Decode(e.to_string()))?;

        let mut picture = Picture::new(
            self.poc as u64,
            std::rc::Rc::clone(&self.context),
            surface.clone(),
        );
        picture.add_buffer(pic_buf);
        picture.add_buffer(slice_buf);
        picture.add_buffer(data_buf);

        let picture = picture
            .begin()
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let picture = picture
            .render()
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        let picture = picture
            .end()
            .map_err(|e| MediaError::Decode(e.to_string()))?;
        picture
            .sync()
            .map_err(|(e, _)| MediaError::Decode(e.to_string()))?;

        self.poc += 1;
        read_nv12_from_surface(&surface, &self.image_fmt, self.width, self.height)
    }
}

fn invalid_hevc_ref_array() -> [PictureHEVC; 15] {
    std::array::from_fn(|_| PictureHEVC::new(bindings::VA_INVALID_SURFACE, 0, 0))
}

fn is_hevc_idr_nal(annex_b: &[u8]) -> bool {
    let mut i = 0;
    while i + 4 < annex_b.len() {
        if annex_b[i..].starts_with(&[0, 0, 0, 1]) {
            i += 4;
        } else if annex_b[i..].starts_with(&[0, 0, 1]) {
            i += 3;
        } else {
            i += 1;
            continue;
        }
        if i < annex_b.len() {
            let nal_type = (annex_b[i] >> 1) & 0x3F;
            if nal_type >= 16 && nal_type <= 21 {
                return true;
            }
        }
    }
    false
}

fn read_nv12_from_surface(
    surface: &cros_libva::surface::Surface,
    image_fmt: &bindings::VAImageFormat,
    width: u32,
    height: u32,
) -> Result<Vec<u8>, MediaError> {
    let image = cros_libva::image::Image::create_from(
        surface,
        *image_fmt,
        (width, height),
        (width, height),
    )
    .map_err(|e| MediaError::Decode(e.to_string()))?;
    let va_image = *image.image();
    let src = image.as_ref();
    let w = width as usize;
    let h = height as usize;
    let mut nv12 = vec![0u8; w * h * 3 / 2];
    let mut dst_y = 0usize;
    let mut src_y = &src[va_image.offsets[0] as usize..];
    for _ in 0..h {
        nv12[dst_y..dst_y + w].copy_from_slice(&src_y[..w]);
        dst_y += w;
        src_y = &src_y[va_image.pitches[0] as usize..];
    }
    let mut dst_uv = w * h;
    let mut src_uv = &src[va_image.offsets[1] as usize..];
    for _ in 0..h / 2 {
        nv12[dst_uv..dst_uv + w].copy_from_slice(&src_uv[..w]);
        dst_uv += w;
        src_uv = &src_uv[va_image.pitches[1] as usize..];
    }
    Ok(nv12)
}

fn create_hevc_seq_buffer(
    context: &Context,
    width: u32,
    height: u32,
    fps: u32,
    opts: &VideoOptions,
    gop: u32,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let seq_fields = HEVCEncSeqFields::new(1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0);
    let scc = HevcEncSeqSccFields::new(0);
    let seq = BufferType::EncSequenceParameter(EncSequenceParameter::HEVC(
        EncSequenceParameterBufferHEVC::new(
            1,
            120,
            0,
            gop,
            gop,
            1,
            opts.bitrate.min(60_000_000),
            width as u16,
            height as u16,
            &seq_fields,
            0,
            2,
            0,
            1,
            1,
            1,
            0,
            0,
            0,
            0,
            Some(HevcEncVuiFields::new(1, 0, 0, 1, 0, 0, 1, 0, 0, 0)),
            1,
            1,
            1,
            fps,
            1,
            240,
            1,
            1,
            &scc,
        ),
    ));
    context
        .create_buffer(seq)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

fn create_hevc_pic_buffer(
    context: &Context,
    surface_id: bindings::VASurfaceID,
    coded_id: bindings::VABufferID,
    ref_frames: &[PictureHEVC; 15],
    is_idr: bool,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let pic_fields = HEVCEncPicFields::new(
        if is_idr { 1 } else { 0 },
        if is_idr { 2 } else { 1 },
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    );
    let scc = HevcEncPicSccFields::new(0);
    let pps = BufferType::EncPictureParameter(EncPictureParameter::HEVC(
        EncPictureParameterBufferHEVC::new(
            PictureHEVC::new(surface_id, 0, 0),
            *ref_frames,
            coded_id,
            0xFF,
            0,
            26,
            0,
            0,
            0,
            0,
            0,
            [0; 19],
            [0; 21],
            0,
            0,
            0,
            0,
            0,
            if is_idr { 19 } else { 1 },
            &pic_fields,
            0,
            0,
            &scc,
        ),
    ));
    context
        .create_buffer(pps)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

fn create_hevc_enc_slice_buffer(
    context: &Context,
    num_ctu: u32,
    is_idr: bool,
) -> Result<cros_libva::buffer::Buffer, MediaError> {
    let ref_list = invalid_hevc_ref_array();
    let slice_fields = HevcEncSliceFields::new(1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0);
    let slice =
        BufferType::EncSliceParameter(EncSliceParameter::HEVC(EncSliceParameterBufferHEVC::new(
            0,
            num_ctu,
            if is_idr { 2 } else { 1 },
            0,
            0,
            0,
            ref_list,
            ref_list,
            0,
            0,
            [0; 15],
            [0; 15],
            [[0; 2]; 15],
            [[0; 2]; 15],
            [0; 15],
            [0; 15],
            [[0; 2]; 15],
            [[0; 2]; 15],
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            &slice_fields,
            0,
            0,
        )));
    context
        .create_buffer(slice)
        .map_err(|e| MediaError::Encode(e.to_string()))
}

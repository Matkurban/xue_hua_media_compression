//! Linux VA-API 硬件编码（H.264 / H.265）。

use cros_libva::bindings;
use cros_libva::buffer::{
    BufferType, EncPictureParameter, EncPictureParameterBufferH264, EncPictureParameterBufferHEVC,
    EncSequenceParameter, EncSequenceParameterBufferH264, EncSequenceParameterBufferHEVC,
    EncSliceParameter, EncSliceParameterBufferH264, EncSliceParameterBufferHEVC, H264EncPicFields,
    H264EncSeqFields, H264VuiFields, HEVCEncPicFields, HEVCEncSeqFields, HevcEncPicSccFields,
    HevcEncSeqSccFields, HevcEncSliceFields, HevcEncVuiFields, MappedCodedBuffer, PictureH264,
    PictureHEVC,
};
use cros_libva::display::Display;
use cros_libva::picture::Picture;
use cros_libva::surface::UsageHint;
use cros_libva::Context;

use crate::api::traits::{MediaError, VideoCodec, VideoOptions};
use crate::video::EncodedFrame;
use crate::video_bitstream::annex_b_has_idr_h264_nal;
use crate::video_frame_collector::EncodedFrameCollector;

use super::Nv12EncoderSink;

/// VA-API 编码 surface 池大小（逐帧轮转，不随视频长度增长）。
const VAAPI_SURFACE_POOL: usize = 4;

pub(super) struct VaapiH264Encoder {
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
    output: EncodedFrameCollector,
}

impl VaapiH264Encoder {
    pub(super) fn open(
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
            output: EncodedFrameCollector::new(VideoCodec::H264, frame_duration),
        })
    }

    pub(super) fn finish(self) -> (Vec<EncodedFrame>, Vec<u8>, Vec<u8>, Vec<u8>) {
        self.output.finish()
    }
}

impl Nv12EncoderSink for VaapiH264Encoder {
    fn frame_count(&self) -> usize {
        self.output.frame_count()
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
        let is_key = annex_b_has_idr_h264_nal(&nal);
        self.output.push_access_unit(nal, is_key);
        Ok(())
    }
}

pub(super) struct VaapiHevcEncoder {
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
    output: EncodedFrameCollector,
}

impl VaapiHevcEncoder {
    pub(super) fn open(
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
            output: EncodedFrameCollector::new(VideoCodec::H265, frame_duration),
        })
    }

    pub(super) fn finish(self) -> (Vec<EncodedFrame>, Vec<u8>, Vec<u8>, Vec<u8>) {
        self.output.finish()
    }
}

impl Nv12EncoderSink for VaapiHevcEncoder {
    fn frame_count(&self) -> usize {
        self.output.frame_count()
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
        self.output.push_access_unit(nal, is_idr);
        if is_idr {
            self.ref_frames = invalid_hevc_ref_array();
        }
        self.ref_frames[frame_index % self.ref_frames.len()] =
            PictureHEVC::new(surface_id, frame_index as i32, 0);
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

fn invalid_hevc_ref_array() -> [PictureHEVC; 15] {
    std::array::from_fn(|_| PictureHEVC::new(bindings::VA_INVALID_SURFACE, 0, 0))
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
            (opts.bitrate / 1000).min(60_000),
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

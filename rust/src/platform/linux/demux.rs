//! Linux MP4 demux + 软解（OpenH264 / VA-API VLD）→ NV12。

use std::fs::File;
use std::io::BufReader;

use cros_libva::bindings;
use cros_libva::buffer::{
    BufferType, HevcLongSliceFlags, HevcPicFields, HevcSliceParsingFields, PictureHEVC,
    PictureParameter, PictureParameterBufferHEVC, SliceParameter, SliceParameterBufferHEVC,
};
use cros_libva::display::Display;
use cros_libva::picture::Picture;
use cros_libva::surface::UsageHint;
use mp4::{Mp4Reader, TrackType};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use crate::api::traits::MediaError;
use crate::video_bitstream::avcc_to_annex_b;
use crate::video_scale::scale_nv12;

use super::Nv12EncoderSink;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum InputCodec {
    H264,
    H265,
}

pub(super) fn detect_input_codec_from_reader(
    mp4: &Mp4Reader<impl std::io::Read + std::io::Seek>,
) -> Result<InputCodec, MediaError> {
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
    } else if fourcc.starts_with("avc") || fourcc.starts_with("h264") {
        Ok(InputCodec::H264)
    } else {
        Err(MediaError::UnsupportedFormat(format!(
            "Linux 视频转码不支持输入编码 ({fourcc})"
        )))
    }
}

pub(super) fn stream_decode_and_encode<E: Nv12EncoderSink>(
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
                // OpenH264 对未凑齐 AU 或 B 帧重排延迟返回 None；跳过该 sample。
            }
        }
        InputCodec::H265 => {
            // HEVC 输入走 VA-API VLD 软解（实验性：slice/POC 参数为简化实现）。
            let mut decoder = HevcVldDecoder::open(src_w, src_h)?;
            for sample_id in 1..=sample_count {
                let sample = mp4
                    .read_sample(track_id, sample_id)
                    .map_err(|e| MediaError::Decode(e.to_string()))?;
                let Some(sample) = sample else { break };
                let annex_b = avcc_to_annex_b(&sample.bytes);
                let nv12 = decoder.decode_sample(&annex_b)?;
                let dec_w = decoder.width();
                let dec_h = decoder.height();
                let scaled = if out_w != dec_w || out_h != dec_h {
                    scale_nv12(&nv12, dec_w, dec_h, out_w, out_h)
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

struct HevcVldDecoder {
    context: std::rc::Rc<cros_libva::Context>,
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

    fn width(&self) -> u32 {
        self.width
    }

    fn height(&self) -> u32 {
        self.height
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

#[cfg(test)]
mod tests {
    use super::*;

    struct TestI420 {
        w: usize,
        h: usize,
        y: Vec<u8>,
        u: Vec<u8>,
        v: Vec<u8>,
    }

    impl YUVSource for TestI420 {
        fn dimensions(&self) -> (usize, usize) {
            (self.w, self.h)
        }

        fn strides(&self) -> (usize, usize, usize) {
            (self.w, self.w / 2, self.w / 2)
        }

        fn y(&self) -> &[u8] {
            &self.y
        }

        fn u(&self) -> &[u8] {
            &self.u
        }

        fn v(&self) -> &[u8] {
            &self.v
        }
    }

    #[test]
    fn i420_to_nv12_interleaves_uv() {
        let yuv = TestI420 {
            w: 2,
            h: 2,
            y: vec![1, 2, 3, 4],
            u: vec![10, 20],
            v: vec![30, 40],
        };
        let nv12 = i420_to_nv12(&yuv);
        assert_eq!(nv12.len(), 2 * 2 * 3 / 2);
        assert_eq!(&nv12[0..4], &[1, 2, 3, 4]);
        assert_eq!(&nv12[4..8], &[10, 30, 20, 40]);
    }

    #[test]
    fn is_hevc_idr_nal_detects_idr() {
        let idr = [0u8, 0, 0, 1, 0x26, 0x01];
        assert!(is_hevc_idr_nal(&idr));
        let trail = [0u8, 0, 0, 1, 0x02, 0x01];
        assert!(!is_hevc_idr_nal(&trail));
    }
}

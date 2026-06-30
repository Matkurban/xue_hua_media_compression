//! 平台 encoder 输出收集：统一 param set 提取与 [`EncodedFrame`] 累积。

use crate::api::traits::VideoCodec;
use crate::video::EncodedFrame;
use crate::video_bitstream::extract_param_sets_for_codec;

/// 各平台硬编 drain 路径共享的帧与参数集收集器。
pub(crate) struct EncodedFrameCollector {
    codec: VideoCodec,
    frame_duration: u32,
    frames: Vec<EncodedFrame>,
    vps: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
}

impl EncodedFrameCollector {
    pub fn new(codec: VideoCodec, frame_duration: u32) -> Self {
        Self {
            codec,
            frame_duration,
            frames: Vec::new(),
            vps: Vec::new(),
            sps: Vec::new(),
            pps: Vec::new(),
        }
    }

    pub fn codec(&self) -> VideoCodec {
        self.codec
    }

    pub fn frame_duration(&self) -> u32 {
        self.frame_duration
    }

    pub fn frame_count(&self) -> usize {
        self.frames.len()
    }

    /// 专用 codec-config buffer（如 Android `CODEC_CONFIG`）：只提取参数集，不追加帧。
    pub fn push_codec_config(&mut self, data: &[u8]) {
        if !self.sps.is_empty() {
            return;
        }
        let (v, s, p) = extract_param_sets_for_codec(self.codec, data);
        self.apply_param_sets(v, s, p);
    }

    /// 追加一条 access unit；若尚未捕获参数集则尝试从 NAL 提取。
    pub fn push_access_unit(&mut self, data: Vec<u8>, is_keyframe: bool) {
        if self.sps.is_empty() {
            let (v, s, p) = extract_param_sets_for_codec(self.codec, &data);
            self.apply_param_sets(v, s, p);
        }
        self.frames.push(EncodedFrame {
            data,
            is_keyframe,
            duration: self.frame_duration,
        });
    }

    pub fn param_sets_ready(&self) -> bool {
        !self.sps.is_empty()
    }

    /// 从 format description 等外部来源写入参数集（如 Apple VideoToolbox）。
    pub fn set_param_sets(&mut self, vps: Vec<u8>, sps: Vec<u8>, pps: Vec<u8>) {
        if !vps.is_empty() {
            self.vps = vps;
        }
        if !sps.is_empty() {
            self.sps = sps;
        }
        if !pps.is_empty() {
            self.pps = pps;
        }
    }

    pub fn finish(self) -> (Vec<EncodedFrame>, Vec<u8>, Vec<u8>, Vec<u8>) {
        (self.frames, self.vps, self.sps, self.pps)
    }

    fn apply_param_sets(&mut self, v: Option<Vec<u8>>, s: Vec<u8>, p: Vec<u8>) {
        if let Some(vv) = v.filter(|v| !v.is_empty()) {
            self.vps = vv;
        }
        if !s.is_empty() {
            self.sps = s;
        }
        if !p.is_empty() {
            self.pps = p;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_access_unit_extracts_h264_param_sets() {
        let mut c = EncodedFrameCollector::new(VideoCodec::H264, 3000);
        let annex = vec![
            0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 0, 1, 0x68, 0xce, 0, 0, 0, 1, 0x65, 0x88,
        ];
        c.push_access_unit(annex.clone(), true);
        let (frames, vps, sps, pps) = c.finish();
        assert_eq!(frames.len(), 1);
        assert!(vps.is_empty());
        assert!(!sps.is_empty());
        assert!(!pps.is_empty());
        assert!(frames[0].is_keyframe);
    }

    #[test]
    fn push_codec_config_does_not_add_frame() {
        let mut c = EncodedFrameCollector::new(VideoCodec::H264, 3000);
        let config = [0u8, 0, 0, 1, 0x67, 0x01, 0, 0, 0, 0, 1, 0x68, 0x02];
        c.push_codec_config(&config);
        c.push_access_unit(vec![0, 0, 0, 1, 0x65, 0x88], false);
        let (frames, _, sps, _) = c.finish();
        assert_eq!(frames.len(), 1);
        assert!(!sps.is_empty());
    }
}

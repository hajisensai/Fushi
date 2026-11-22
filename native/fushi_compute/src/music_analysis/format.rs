//! 结果文件格式（`.fma`，小端）。Dart 侧（`fushi/lib/src/media/music/analysis/music_audio_analysis.dart`）
//! 整份读进来、按偏移切 TypedData 视图，逐帧取值不跨 FFI。**改布局必须升 [FORMAT_VERSION]**（两侧同改）。
//!
//! ```text
//! 偏移  类型   含义
//!  0    [u8;4] 魔数 "FMA1"
//!  4    u32    格式版本 = FORMAT_VERSION
//!  8    u32    flags（FLAG_*）
//! 12    f32    包络帧率（帧 / 秒，22050 / 256）
//! 16    u32    包络帧数 F
//! 20    f32    BPM（0 = 未知）
//! 24    u32    每小节拍数
//! 28    u32    拍点数 B
//! 32    u32    强拍数 D
//! 36    u32    鼓点数 H
//! 40    u32    人声起音数 V
//! 44    u32    时长（毫秒）
//! 48    u32    分析管线版本（PIPELINE_VERSION）
//! 52..64       保留（0）
//! 64    u8[F] × 6  包络：power、low、mid、high、onset、vocal（各 F 字节，0–255 ↔ 0–1），总长补齐到 4 的倍数
//!       i32[B] 拍点（毫秒，升序）
//!       i32[D] 强拍（毫秒，升序，拍点子集）
//!       i32[H] 鼓点时间（毫秒，升序）
//!       u8[H]  鼓点强度（0–255）
//!       u8[H]  鼓点类别（0 底鼓 / 1 军鼓 / 2 镲片），之后补齐到 4 的倍数
//!       i32[V] 人声起音（毫秒，升序）
//! ```

/// 魔数。
pub(crate) const MAGIC: &[u8; 4] = b"FMA1";
/// 文件布局版本。
pub const FORMAT_VERSION: u32 = 1;
/// 分析算法版本：改了常数 / 算法就升，Dart 侧据此判旧缓存作废重算。
pub const PIPELINE_VERSION: u32 = 1;
/// 头长。
pub(crate) const HEADER_BYTES: usize = 64;

/// 拍点来自 Beat This!（否则是 DSP 退路）。
pub const FLAG_BEATS_MODEL: u32 = 1 << 0;
/// 鼓点来自 htdemucs 鼓轨（否则是 HPSS 打击成分）。
pub const FLAG_DRUMS_MODEL: u32 = 1 << 1;
/// 人声来自 htdemucs 人声轨（否则是混音的人声频段）。
pub const FLAG_VOCAL_MODEL: u32 = 1 << 2;
/// 判为没鼓的歌（只在鼓轨路径上判；鼓点表为空）。
pub const FLAG_DRUMLESS: u32 = 1 << 3;

/// 一首歌的完整结果。
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Analysis {
    pub(crate) flags: u32,
    pub(crate) frame_rate: f32,
    /// 六条包络（0–1）：power、low、mid、high、onset、vocal。
    pub(crate) power: Vec<f32>,
    pub(crate) low: Vec<f32>,
    pub(crate) mid: Vec<f32>,
    pub(crate) high: Vec<f32>,
    pub(crate) onset: Vec<f32>,
    pub(crate) vocal: Vec<f32>,
    pub(crate) bpm: Option<f64>,
    pub(crate) beats_per_bar: u32,
    pub(crate) beats_ms: Vec<i32>,
    pub(crate) downbeats_ms: Vec<i32>,
    pub(crate) hits_ms: Vec<i32>,
    pub(crate) hit_strength: Vec<f32>,
    pub(crate) hit_kind: Vec<u8>,
    pub(crate) vocal_onsets_ms: Vec<i32>,
    pub(crate) duration_ms: u32,
}

fn q8(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u8
}

fn pad4(out: &mut Vec<u8>) {
    while out.len() % 4 != 0 {
        out.push(0);
    }
}

/// 秒 → 毫秒（四舍五入）。
pub(crate) fn ms(seconds: f64) -> i32 {
    (seconds * 1000.0).round() as i32
}

impl Analysis {
    pub(crate) fn frames(&self) -> usize {
        self.power.len()
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let f = self.frames();
        let h = self.hits_ms.len();
        let mut out = Vec::with_capacity(
            HEADER_BYTES + 6 * f + 4 * (self.beats_ms.len() + self.downbeats_ms.len()) + 6 * h + 8,
        );
        out.extend_from_slice(MAGIC);
        for v in [FORMAT_VERSION, self.flags] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&self.frame_rate.to_le_bytes());
        out.extend_from_slice(&(f as u32).to_le_bytes());
        out.extend_from_slice(&(self.bpm.unwrap_or(0.0) as f32).to_le_bytes());
        for v in [
            self.beats_per_bar,
            self.beats_ms.len() as u32,
            self.downbeats_ms.len() as u32,
            h as u32,
            self.vocal_onsets_ms.len() as u32,
            self.duration_ms,
            PIPELINE_VERSION,
        ] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.resize(HEADER_BYTES, 0);
        for series in [
            &self.power,
            &self.low,
            &self.mid,
            &self.high,
            &self.onset,
            &self.vocal,
        ] {
            debug_assert_eq!(series.len(), f);
            out.extend(series.iter().map(|v| q8(*v)));
        }
        pad4(&mut out);
        for list in [&self.beats_ms, &self.downbeats_ms, &self.hits_ms] {
            for v in list.iter() {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        out.extend(self.hit_strength.iter().map(|v| q8(*v)));
        out.extend_from_slice(&self.hit_kind);
        pad4(&mut out);
        for v in &self.vocal_onsets_ms {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// 读回（测试与「已有结果再补模型那一步」用）。格式不对为 None。
    pub(crate) fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < HEADER_BYTES || &bytes[0..4] != MAGIC {
            return None;
        }
        let u32_at = |o: usize| u32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        let f32_at = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        if u32_at(4) != FORMAT_VERSION || u32_at(48) != PIPELINE_VERSION {
            return None;
        }
        let f = u32_at(16) as usize;
        let (b, d, h, v) = (
            u32_at(28) as usize,
            u32_at(32) as usize,
            u32_at(36) as usize,
            u32_at(40) as usize,
        );
        let env_end = HEADER_BYTES + (6 * f).div_ceil(4) * 4;
        let times_end = env_end + 4 * (b + d + h);
        let hits_end = times_end + (2 * h).div_ceil(4) * 4;
        if bytes.len() < hits_end + 4 * v {
            return None;
        }
        let series = |i: usize| -> Vec<f32> {
            bytes[HEADER_BYTES + i * f..HEADER_BYTES + (i + 1) * f]
                .iter()
                .map(|b| f32::from(*b) / 255.0)
                .collect()
        };
        let ints = |from: usize, n: usize| -> Vec<i32> {
            (0..n)
                .map(|k| {
                    i32::from_le_bytes(bytes[from + 4 * k..from + 4 * k + 4].try_into().unwrap())
                })
                .collect()
        };
        let bpm = f32_at(20);
        Some(Self {
            flags: u32_at(8),
            frame_rate: f32_at(12),
            power: series(0),
            low: series(1),
            mid: series(2),
            high: series(3),
            onset: series(4),
            vocal: series(5),
            bpm: (bpm > 0.0).then_some(f64::from(bpm)),
            beats_per_bar: u32_at(24),
            beats_ms: ints(env_end, b),
            downbeats_ms: ints(env_end + 4 * b, d),
            hits_ms: ints(env_end + 4 * (b + d), h),
            hit_strength: bytes[times_end..times_end + h]
                .iter()
                .map(|v| f32::from(*v) / 255.0)
                .collect(),
            hit_kind: bytes[times_end + h..times_end + 2 * h].to_vec(),
            vocal_onsets_ms: ints(hits_end, v),
            duration_ms: u32_at(44),
        })
    }
}

/// 原子写：先写同目录临时文件再改名，读者永远看不到半截文件。
pub(crate) fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        // Windows：目标被别的句柄占着时 rename 会失败；先删再改名。
        let _ = std::fs::remove_file(path);
        std::fs::rename(&tmp, path).map_err(|_| e)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let a = Analysis {
            flags: FLAG_BEATS_MODEL | FLAG_DRUMLESS,
            frame_rate: 86.132_81,
            power: vec![0.0, 0.5, 1.0],
            low: vec![1.0, 0.0, 0.2],
            mid: vec![0.1, 0.2, 0.3],
            high: vec![0.3, 0.2, 0.1],
            onset: vec![0.0, 1.0, 0.0],
            vocal: vec![0.4, 0.4, 0.4],
            bpm: Some(128.0),
            beats_per_bar: 4,
            beats_ms: vec![10, 478, 947],
            downbeats_ms: vec![10],
            hits_ms: vec![12, 480],
            hit_strength: vec![1.0, 0.5],
            hit_kind: vec![0, 2],
            vocal_onsets_ms: vec![300],
            duration_ms: 1234,
        };
        let bytes = a.encode();
        assert_eq!(&bytes[0..4], b"FMA1");
        assert_eq!(bytes.len() % 4, 0);
        let b = Analysis::decode(&bytes).unwrap();
        assert_eq!(b.beats_ms, a.beats_ms);
        assert_eq!(b.downbeats_ms, a.downbeats_ms);
        assert_eq!(b.hits_ms, a.hits_ms);
        assert_eq!(b.hit_kind, a.hit_kind);
        assert_eq!(b.vocal_onsets_ms, a.vocal_onsets_ms);
        assert_eq!(b.flags, a.flags);
        assert_eq!(b.bpm, Some(128.0));
        assert_eq!(b.duration_ms, 1234);
        assert!((b.hit_strength[1] - 0.5).abs() < 0.01);
        assert!((b.power[1] - 0.5).abs() < 0.01);
        assert_eq!(b.frames(), 3);
    }

    #[test]
    fn rejects_garbage_and_other_versions() {
        assert!(Analysis::decode(b"nope").is_none());
        let mut bytes = Analysis {
            frame_rate: 86.0,
            ..Default::default()
        }
        .encode();
        bytes[4] = 99;
        assert!(Analysis::decode(&bytes).is_none());
    }
}

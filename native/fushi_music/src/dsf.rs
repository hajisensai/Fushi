//! DSF（Sony DSD Stream File）头部：lofty 不认 DSF，音频属性从 `DSD ` / `fmt ` 两个定长
//! 块直接读。DSD 是 1 bit；码率 = 采样率 × 声道数。DSF 文件尾的 ID3v2 标签 P0 不读
//! （标题退回文件名），随 P2「DSD 处理」一起补。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DsfInfo {
    pub sample_rate: u32,
    pub channels: u32,
    pub duration_ms: i64,
}

/// `head` 至少要有文件前 80 字节（28 字节 `DSD ` 块 + 52 字节 `fmt ` 块）。
pub fn parse_header(head: &[u8]) -> Option<DsfInfo> {
    if head.len() < 80 || &head[0..4] != b"DSD " || &head[28..32] != b"fmt " {
        return None;
    }
    let u32_at = |o: usize| u32::from_le_bytes(head[o..o + 4].try_into().unwrap());
    let u64_at = |o: usize| u64::from_le_bytes(head[o..o + 8].try_into().unwrap());
    // fmt 块：id(4) size(8) version(4) format_id(4) channel_type(4) channel_num(4)
    //        sampling_frequency(4) bits_per_sample(4) sample_count(8) ...
    let channels = u32_at(28 + 24);
    let sample_rate = u32_at(28 + 28);
    let sample_count = u64_at(28 + 36);
    if sample_rate == 0 || channels == 0 {
        return None;
    }
    Some(DsfInfo {
        sample_rate,
        channels,
        duration_ms: (sample_count.saturating_mul(1000) / sample_rate as u64) as i64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn synth_header(sample_rate: u32, channels: u32, samples: u64) -> Vec<u8> {
        let mut h = Vec::new();
        h.extend_from_slice(b"DSD ");
        h.extend_from_slice(&28u64.to_le_bytes());
        h.extend_from_slice(&0u64.to_le_bytes());
        h.extend_from_slice(&0u64.to_le_bytes());
        h.extend_from_slice(b"fmt ");
        h.extend_from_slice(&52u64.to_le_bytes());
        h.extend_from_slice(&1u32.to_le_bytes()); // version
        h.extend_from_slice(&0u32.to_le_bytes()); // format id
        h.extend_from_slice(&2u32.to_le_bytes()); // channel type
        h.extend_from_slice(&channels.to_le_bytes());
        h.extend_from_slice(&sample_rate.to_le_bytes());
        h.extend_from_slice(&1u32.to_le_bytes()); // bits per sample
        h.extend_from_slice(&samples.to_le_bytes());
        h.extend_from_slice(&4096u32.to_le_bytes());
        h.extend_from_slice(&0u32.to_le_bytes());
        h
    }

    #[test]
    fn reads_dsd64_header() {
        let info = parse_header(&synth_header(2_822_400, 2, 2_822_400 * 3)).unwrap();
        assert_eq!(info.sample_rate, 2_822_400);
        assert_eq!(info.channels, 2);
        assert_eq!(info.duration_ms, 3000);
        assert!(parse_header(b"RIFF").is_none());
    }
}

//! 缩略图宿主进程 → 资源管理器里的处理器之间的 stdout 协议。
//!
//! `b"FTHB"` + `u32 宽` + `u32 高`（小端）+ `宽*高*4` 字节 BGRA（自上而下）。
//! 处理器那一侧把宿主当不可信：尺寸超出请求的边长、长度对不上一律拒收。

use std::io::Read;

use crate::{ThumbError, Thumbnail};

const MAGIC: &[u8; 4] = b"FTHB";
const HEADER_LEN: usize = 12;

/// 资源管理器请求的边长上限（超大图标视图是 256，高 DPI 下最多到 2560 左右）。
pub const MAX_EDGE: u32 = 4096;

/// 给定边长下，一帧最大字节数（读宿主输出时的上限）。
pub fn max_frame_len(cx: u32) -> usize {
    let edge = cx.clamp(1, MAX_EDGE) as usize;
    HEADER_LEN + edge * edge * 4
}

pub fn encode(t: &Thumbnail) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + t.bgra.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&t.width.to_le_bytes());
    out.extend_from_slice(&t.height.to_le_bytes());
    out.extend_from_slice(&t.bgra);
    out
}

/// 解析并校验一帧：宽高都在 `1..=cx` 内，像素长度恰好对得上。
pub fn decode(frame: &[u8], cx: u32) -> Result<Thumbnail, ThumbError> {
    let bad = |m: &str| ThumbError::Corrupt(format!("host frame: {m}"));
    if frame.len() < HEADER_LEN || &frame[..4] != MAGIC {
        return Err(bad("missing header"));
    }
    let width = u32::from_le_bytes(frame[4..8].try_into().unwrap());
    let height = u32::from_le_bytes(frame[8..12].try_into().unwrap());
    check_header(frame, width, height, cx)?;
    let expected = width as usize * height as usize * 4;
    if frame.len() - HEADER_LEN != expected {
        return Err(bad("pixel length mismatch"));
    }
    Ok(Thumbnail {
        width,
        height,
        bgra: frame[HEADER_LEN..].to_vec(),
    })
}

/// 从流里读**恰好一帧**（先读帧头、校验尺寸，再读对应的像素字节），不依赖 EOF。
pub fn read_frame<R: Read>(mut r: R, cx: u32) -> Result<Thumbnail, ThumbError> {
    let mut header = [0u8; HEADER_LEN];
    r.read_exact(&mut header)
        .map_err(|e| ThumbError::Corrupt(format!("host frame: {e}")))?;
    let width = u32::from_le_bytes(header[4..8].try_into().unwrap());
    let height = u32::from_le_bytes(header[8..12].try_into().unwrap());
    check_header(&header, width, height, cx)?;
    let mut bgra = vec![0u8; width as usize * height as usize * 4];
    r.read_exact(&mut bgra)
        .map_err(|e| ThumbError::Corrupt(format!("host frame: {e}")))?;
    Ok(Thumbnail {
        width,
        height,
        bgra,
    })
}

fn check_header(header: &[u8], width: u32, height: u32, cx: u32) -> Result<(), ThumbError> {
    if &header[..4] != MAGIC {
        return Err(ThumbError::Corrupt("host frame: missing header".into()));
    }
    let limit = cx.clamp(1, MAX_EDGE);
    if width == 0 || height == 0 || width > limit || height > limit {
        return Err(ThumbError::Corrupt("host frame: size out of range".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_frame_stops_after_one_frame() {
        let t = thumb(2, 3);
        let mut bytes = encode(&t);
        bytes.extend_from_slice(b"trailing bytes that must not be awaited");
        assert_eq!(read_frame(std::io::Cursor::new(bytes), 256), Ok(t));
        let short = &encode(&thumb(2, 3))[..20];
        assert!(read_frame(short, 256).is_err());
        assert!(read_frame(&encode(&thumb(300, 1))[..], 256).is_err());
    }

    fn thumb(w: u32, h: u32) -> Thumbnail {
        Thumbnail {
            width: w,
            height: h,
            bgra: (0..w * h * 4).map(|i| i as u8).collect(),
        }
    }

    #[test]
    fn round_trips() {
        let t = thumb(3, 2);
        assert_eq!(decode(&encode(&t), 256), Ok(t));
    }

    #[test]
    fn rejects_oversized_truncated_and_foreign_frames() {
        assert!(decode(&encode(&thumb(300, 1)), 256).is_err());
        let mut f = encode(&thumb(2, 2));
        f.pop();
        assert!(decode(&f, 256).is_err());
        assert!(decode(b"NOPE\x01\0\0\0\x01\0\0\0abcd", 256).is_err());
        assert!(decode(b"", 256).is_err());
        let zero = Thumbnail {
            width: 0,
            height: 5,
            bgra: vec![],
        };
        assert!(decode(&encode(&zero), 256).is_err());
    }

    #[test]
    fn frame_limit_tracks_requested_edge() {
        assert_eq!(max_frame_len(256), 12 + 256 * 256 * 4);
        assert_eq!(max_frame_len(0), 12 + 4);
        assert_eq!(max_frame_len(u32::MAX), 12 + 4096 * 4096 * 4);
    }
}

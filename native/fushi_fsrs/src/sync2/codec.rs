//! 紧凑二进制编码（设计 §3.3）：LEB128 无符号 varint、zigzag 有符号、长度前缀的字节串 / 字符串。
//!
//! 操作、段、head、快照都用这一套；不依赖 serde，字节布局由本文件逐字段决定（跨平台、跨版本稳定）。

/// 解码错误：截断或格式不对。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError(pub &'static str);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "decode: {}", self.0)
    }
}

impl std::error::Error for DecodeError {}

pub type DResult<T> = Result<T, DecodeError>;

/// 追加写。
#[derive(Debug, Default, Clone)]
pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Self { buf: Vec::new() }
    }

    pub fn with_capacity(n: usize) -> Self {
        Self { buf: Vec::with_capacity(n) }
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.buf
    }

    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn uv(&mut self, mut v: u64) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                self.buf.push(b);
                return;
            }
            self.buf.push(b | 0x80);
        }
    }

    pub fn iv(&mut self, v: i64) {
        self.uv(((v << 1) ^ (v >> 63)) as u64);
    }

    pub fn raw(&mut self, b: &[u8]) {
        self.buf.extend_from_slice(b);
    }

    pub fn bytes(&mut self, b: &[u8]) {
        self.uv(b.len() as u64);
        self.buf.extend_from_slice(b);
    }

    pub fn str(&mut self, s: &str) {
        self.bytes(s.as_bytes());
    }

    pub fn f64(&mut self, v: f64) {
        self.buf.extend_from_slice(&v.to_bits().to_le_bytes());
    }

    pub fn f32(&mut self, v: f32) {
        self.buf.extend_from_slice(&v.to_bits().to_le_bytes());
    }

    pub fn bool(&mut self, v: bool) {
        self.buf.push(u8::from(v));
    }

    /// 可空 i64：0 = 空，否则 1 + zigzag。
    pub fn opt_iv(&mut self, v: Option<i64>) {
        match v {
            None => self.buf.push(0),
            Some(x) => {
                self.buf.push(1);
                self.iv(x);
            }
        }
    }

    pub fn opt_str(&mut self, v: Option<&str>) {
        match v {
            None => self.buf.push(0),
            Some(s) => {
                self.buf.push(1);
                self.str(s);
            }
        }
    }
}

/// 顺序读。
#[derive(Debug, Clone)]
pub struct Reader<'a> {
    pub buf: &'a [u8],
    pub pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    pub fn is_empty(&self) -> bool {
        self.pos >= self.buf.len()
    }

    pub fn remaining(&self) -> &'a [u8] {
        &self.buf[self.pos..]
    }

    pub fn u8(&mut self) -> DResult<u8> {
        let b = *self.buf.get(self.pos).ok_or(DecodeError("truncated u8"))?;
        self.pos += 1;
        Ok(b)
    }

    pub fn uv(&mut self) -> DResult<u64> {
        let mut out: u64 = 0;
        let mut shift = 0u32;
        loop {
            let b = self.u8()?;
            if shift == 63 && b > 1 {
                return Err(DecodeError("varint overflow"));
            }
            out |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(out);
            }
            shift += 7;
            if shift > 63 {
                return Err(DecodeError("varint overflow"));
            }
        }
    }

    pub fn iv(&mut self) -> DResult<i64> {
        let u = self.uv()?;
        Ok(((u >> 1) as i64) ^ -((u & 1) as i64))
    }

    pub fn raw(&mut self, n: usize) -> DResult<&'a [u8]> {
        let end = self.pos.checked_add(n).ok_or(DecodeError("length overflow"))?;
        if end > self.buf.len() {
            return Err(DecodeError("truncated bytes"));
        }
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    pub fn bytes(&mut self) -> DResult<&'a [u8]> {
        let n = self.uv()?;
        let n = usize::try_from(n).map_err(|_| DecodeError("length overflow"))?;
        self.raw(n)
    }

    pub fn str(&mut self) -> DResult<&'a str> {
        std::str::from_utf8(self.bytes()?).map_err(|_| DecodeError("bad utf-8"))
    }

    pub fn f64(&mut self) -> DResult<f64> {
        let b: [u8; 8] = self.raw(8)?.try_into().map_err(|_| DecodeError("f64"))?;
        Ok(f64::from_bits(u64::from_le_bytes(b)))
    }

    pub fn f32(&mut self) -> DResult<f32> {
        let b: [u8; 4] = self.raw(4)?.try_into().map_err(|_| DecodeError("f32"))?;
        Ok(f32::from_bits(u32::from_le_bytes(b)))
    }

    pub fn bool(&mut self) -> DResult<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(DecodeError("bad bool")),
        }
    }

    pub fn opt_iv(&mut self) -> DResult<Option<i64>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.iv()?)),
            _ => Err(DecodeError("bad option tag")),
        }
    }

    pub fn opt_str(&mut self) -> DResult<Option<&'a str>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.str()?)),
            _ => Err(DecodeError("bad option tag")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_round_trip_at_the_edges() {
        let us = [0u64, 1, 127, 128, 16383, 16384, u32::MAX as u64, u64::MAX];
        let is = [0i64, -1, 1, -64, 64, i64::MIN, i64::MAX];
        let mut w = Writer::new();
        for &u in &us {
            w.uv(u);
        }
        for &i in &is {
            w.iv(i);
        }
        let buf = w.into_vec();
        let mut r = Reader::new(&buf);
        for &u in &us {
            assert_eq!(r.uv().unwrap(), u);
        }
        for &i in &is {
            assert_eq!(r.iv().unwrap(), i);
        }
        assert!(r.is_empty());
    }

    #[test]
    fn truncated_input_is_an_error_not_a_panic() {
        let mut w = Writer::new();
        w.str("hello");
        let buf = w.into_vec();
        for n in 0..buf.len() {
            assert!(Reader::new(&buf[..n]).str().is_err());
        }
        assert!(Reader::new(&[0xff; 11]).uv().is_err());
    }
}

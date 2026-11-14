// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 内核与宿主之间消息的编码：小端、顺序读写，没有自描述标签（两边按 `mod.rs` 文件头的表各写各的）。

#[derive(Default)]
pub struct Writer(pub Vec<u8>);

impl Writer {
    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.0.push(v);
        self
    }

    pub fn bool(&mut self, v: bool) -> &mut Self {
        self.u8(u8::from(v))
    }

    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn i64(&mut self, v: i64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn f32(&mut self, v: f32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn opt_i64(&mut self, v: Option<i64>) -> &mut Self {
        self.bool(v.is_some()).i64(v.unwrap_or(0))
    }

    pub fn str(&mut self, v: &str) -> &mut Self {
        self.bytes(v.as_bytes())
    }

    pub fn opt_str(&mut self, v: Option<&str>) -> &mut Self {
        self.bool(v.is_some()).str(v.unwrap_or(""))
    }

    /// 长度（u32）+ 原始字节。
    pub fn bytes(&mut self, v: &[u8]) -> &mut Self {
        self.u32(v.len() as u32);
        self.0.extend_from_slice(v);
        self
    }

    pub fn i64s(&mut self, v: &[i64]) -> &mut Self {
        self.u32(v.len() as u32);
        for x in v {
            self.i64(*x);
        }
        self
    }

    pub fn u64s(&mut self, v: &[u64]) -> &mut Self {
        self.u32(v.len() as u32);
        for x in v {
            self.u64(*x);
        }
        self
    }
}

pub struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

type Read<T> = Result<T, String>;

impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    pub fn position(&self) -> usize {
        self.at
    }

    #[cfg(test)]
    pub fn done(&self) -> bool {
        self.at >= self.bytes.len()
    }

    pub fn take(&mut self, len: usize) -> Read<&'a [u8]> {
        let end = self
            .at
            .checked_add(len)
            .filter(|end| *end <= self.bytes.len())
            .ok_or_else(|| format!("message truncated at byte {}", self.at))?;
        let out = &self.bytes[self.at..end];
        self.at = end;
        Ok(out)
    }

    pub fn u8(&mut self) -> Read<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn bool(&mut self) -> Read<bool> {
        Ok(self.u8()? != 0)
    }

    pub fn u32(&mut self) -> Read<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn i64(&mut self) -> Read<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    #[cfg(test)]
    pub fn u64(&mut self) -> Read<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    pub fn opt_i64(&mut self) -> Read<Option<i64>> {
        let has = self.bool()?;
        let v = self.i64()?;
        Ok(has.then_some(v))
    }

    pub fn bytes(&mut self) -> Read<&'a [u8]> {
        let len = self.u32()? as usize;
        self.take(len)
    }

    pub fn str(&mut self) -> Read<String> {
        String::from_utf8(self.bytes()?.to_vec()).map_err(|e| format!("message text: {e}"))
    }

    pub fn opt_str(&mut self) -> Read<Option<String>> {
        let has = self.bool()?;
        let v = self.str()?;
        Ok(has.then_some(v))
    }

    pub fn i64s(&mut self) -> Read<Vec<i64>> {
        let n = self.u32()? as usize;
        Ok(le_i64s(self.take(
            n.checked_mul(8).ok_or("message length overflow")?,
        )?))
    }

    pub fn u64s(&mut self) -> Read<Vec<u64>> {
        let n = self.u32()? as usize;
        Ok(self
            .take(n.checked_mul(8).ok_or("message length overflow")?)?
            .chunks_exact(8)
            .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
            .collect())
    }

    pub fn f32s(&mut self) -> Read<Vec<f32>> {
        let n = self.u32()? as usize;
        Ok(self
            .take(n.checked_mul(4).ok_or("message length overflow")?)?
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect())
    }
}

pub fn le_i64(bytes: &[u8], index: usize) -> i64 {
    i64::from_le_bytes(bytes[8 * index..8 * index + 8].try_into().unwrap())
}

pub fn le_i64s(bytes: &[u8]) -> Vec<i64> {
    bytes
        .chunks_exact(8)
        .map(|b| i64::from_le_bytes(b.try_into().unwrap()))
        .collect()
}

pub fn le_u64s(bytes: &[u8]) -> Vec<u64> {
    bytes
        .chunks_exact(8)
        .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
        .collect()
}

//! 线格式与磁盘格式共用的小端读写原语，以及三份跨边界约定：
//!
//! - **文档**（Dart → `fcorp_put`）：
//!   `u8 kind, str key, i32 part, str title, str fingerprint, str normalizer, i64 updatedAt,
//!    u32 N, N × { i32 section, i64 pos, i64 len, str text }`
//! - **词元**（fushidicts `fushidicts_corpus_terms` 的输出，Dart 原样转交，不解码）：
//!   `N × { u32 M, M × { u32 start16, u32 len16, str lemma } }`
//!   ——与 `native/fushidicts/fushidicts_ffi.cpp` 的注释是同一份约定。
//! - **查询**（Dart → `fcorp_query`）：
//!   `u32 K, K × str key, u32 perKind, u32 perDoc, u32 kindMask`
//!
//! `str` = `u32 UTF-8 字节数 + 字节`。

#[derive(Debug)]
pub struct WireError(pub &'static str);

pub struct Reader<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, at: 0 }
    }

    pub fn position(&self) -> usize {
        self.at
    }

    pub fn is_empty(&self) -> bool {
        self.at >= self.data.len()
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], WireError> {
        if self.data.len() - self.at < n {
            return Err(WireError("truncated"));
        }
        let s = &self.data[self.at..self.at + n];
        self.at += n;
        Ok(s)
    }

    pub fn u8(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }

    pub fn u32(&mut self) -> Result<u32, WireError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn i32(&mut self) -> Result<i32, WireError> {
        Ok(self.u32()? as i32)
    }

    pub fn i64(&mut self) -> Result<i64, WireError> {
        let b = self.take(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        Ok(i64::from_le_bytes(a))
    }

    pub fn bytes(&mut self) -> Result<&'a [u8], WireError> {
        let n = self.u32()? as usize;
        self.take(n)
    }

    pub fn str(&mut self) -> Result<&'a str, WireError> {
        std::str::from_utf8(self.bytes()?).map_err(|_| WireError("invalid utf-8"))
    }

    /// 跳过一个 `str`，返回它的字节区间（相对整段数据）。
    pub fn skip_str(&mut self) -> Result<(usize, usize), WireError> {
        let n = self.u32()? as usize;
        let start = self.at;
        self.take(n)?;
        Ok((start, n))
    }
}

#[derive(Default)]
pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }
    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    pub fn i32(&mut self, v: i32) {
        self.u32(v as u32);
    }
    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    pub fn str(&mut self, s: &str) {
        self.u32(s.len() as u32);
        self.buf.extend_from_slice(s.as_bytes());
    }
}

/// Dart 传来的一个句子。
pub struct InSentence<'a> {
    pub section: i32,
    pub pos: i64,
    pub len: i64,
    pub text: &'a str,
}

/// Dart 传来的一份文档（不含词元）。
pub struct InDocument<'a> {
    pub kind: u8,
    pub key: &'a str,
    pub part: i32,
    pub title: &'a str,
    pub fingerprint: &'a str,
    pub normalizer: &'a str,
    pub updated_at: i64,
    pub sentences: Vec<InSentence<'a>>,
}

pub fn read_document(data: &[u8]) -> Result<InDocument<'_>, WireError> {
    let mut r = Reader::new(data);
    let kind = r.u8()?;
    let key = r.str()?;
    let part = r.i32()?;
    let title = r.str()?;
    let fingerprint = r.str()?;
    let normalizer = r.str()?;
    let updated_at = r.i64()?;
    let n = r.u32()? as usize;
    let mut sentences = Vec::with_capacity(n.min(1 << 20));
    for _ in 0..n {
        sentences.push(InSentence { section: r.i32()?, pos: r.i64()?, len: r.i64()?, text: r.str()? });
    }
    if !r.is_empty() {
        return Err(WireError("trailing bytes in document"));
    }
    Ok(InDocument { kind, key, part, title, fingerprint, normalizer, updated_at, sentences })
}

/// 一个词元（fushidicts 给出的词典形 + 句内 UTF-16 区间）。
pub struct InToken<'a> {
    pub start: u32,
    pub len: u32,
    pub lemma: &'a str,
}

/// 读 [count] 句的词元；词元数据与句数对不上（截断 / 多余字节）即报错。
pub fn read_terms(data: &[u8], count: usize) -> Result<Vec<Vec<InToken<'_>>>, WireError> {
    let mut r = Reader::new(data);
    let mut out = Vec::with_capacity(count.min(1 << 20));
    for _ in 0..count {
        let m = r.u32()? as usize;
        let mut tokens = Vec::with_capacity(m.min(4096));
        for _ in 0..m {
            tokens.push(InToken { start: r.u32()?, len: r.u32()?, lemma: r.str()? });
        }
        out.push(tokens);
    }
    if !r.is_empty() {
        return Err(WireError("trailing bytes in terms"));
    }
    Ok(out)
}

pub struct InQuery<'a> {
    pub keys: Vec<&'a str>,
    pub per_kind: usize,
    pub per_doc: usize,
    pub kind_mask: u32,
}

pub fn read_query(data: &[u8]) -> Result<InQuery<'_>, WireError> {
    let mut r = Reader::new(data);
    let k = r.u32()? as usize;
    let mut keys = Vec::with_capacity(k.min(64));
    for _ in 0..k {
        keys.push(r.str()?);
    }
    let per_kind = r.u32()? as usize;
    let per_doc = r.u32()? as usize;
    let kind_mask = r.u32()?;
    if !r.is_empty() {
        return Err(WireError("trailing bytes in query"));
    }
    Ok(InQuery { keys, per_kind, per_doc, kind_mask })
}

/// JSON 字符串转义（输出只给 Dart `jsonDecode` 读）。
pub fn json_str(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

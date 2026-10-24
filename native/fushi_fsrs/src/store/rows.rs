//! 行页的二进制编码（搬迁页、调试查询的结果）。小端：
//!
//! ```text
//! u32 行数  u32 列数
//! 逐行逐列：u8 标记  0 = NULL
//!                    1 = 整数   i64
//!                    2 = 浮点   f64
//!                    3 = 文本   u32 字节数 + UTF-8
//!                    4 = 字节   u32 字节数 + 原样
//! ```
//!
//! 不走 JSON：日志 / 修改记录本身就是 JSON 文本，再包一层要转义、反转义两遍。

use rusqlite::types::{Value, ValueRef};

pub fn encode(columns: usize, rows: &[Vec<Value>]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + rows.len() * columns * 9);
    out.extend_from_slice(&(rows.len() as u32).to_le_bytes());
    out.extend_from_slice(&(columns as u32).to_le_bytes());
    for row in rows {
        for v in row {
            push_value(&mut out, v.into());
        }
    }
    out
}

pub fn push_value(out: &mut Vec<u8>, v: ValueRef<'_>) {
    match v {
        ValueRef::Null => out.push(0),
        ValueRef::Integer(i) => {
            out.push(1);
            out.extend_from_slice(&i.to_le_bytes());
        }
        ValueRef::Real(f) => {
            out.push(2);
            out.extend_from_slice(&f.to_le_bytes());
        }
        ValueRef::Text(t) => {
            out.push(3);
            out.extend_from_slice(&(t.len() as u32).to_le_bytes());
            out.extend_from_slice(t);
        }
        ValueRef::Blob(b) => {
            out.push(4);
            out.extend_from_slice(&(b.len() as u32).to_le_bytes());
            out.extend_from_slice(b);
        }
    }
}

/// 解出一页：返回 (列数, 行)。任何越界 / 坏标记 / 非 UTF-8 文本都报错，不猜。
pub fn decode(bytes: &[u8]) -> Result<(usize, Vec<Vec<Value>>), String> {
    let mut r = Reader { bytes, at: 0 };
    let n_rows = r.u32()? as usize;
    let n_cols = r.u32()? as usize;
    let mut rows = Vec::with_capacity(n_rows.min(1 << 20));
    for _ in 0..n_rows {
        let mut row = Vec::with_capacity(n_cols);
        for _ in 0..n_cols {
            row.push(r.value()?);
        }
        rows.push(row);
    }
    if r.at != bytes.len() {
        return Err(format!("trailing bytes in row page: {}", bytes.len() - r.at));
    }
    Ok((n_cols, rows))
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(n).ok_or("row page overflow")?;
        if end > self.bytes.len() {
            return Err("truncated row page".into());
        }
        let s = &self.bytes[self.at..end];
        self.at = end;
        Ok(s)
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn value(&mut self) -> Result<Value, String> {
        let tag = self.take(1)?[0];
        Ok(match tag {
            0 => Value::Null,
            1 => Value::Integer(i64::from_le_bytes(self.take(8)?.try_into().unwrap())),
            2 => Value::Real(f64::from_le_bytes(self.take(8)?.try_into().unwrap())),
            3 => {
                let n = self.u32()? as usize;
                let s = std::str::from_utf8(self.take(n)?).map_err(|e| e.to_string())?;
                Value::Text(s.to_owned())
            }
            4 => {
                let n = self.u32()? as usize;
                Value::Blob(self.take(n)?.to_vec())
            }
            other => return Err(format!("bad value tag {other}")),
        })
    }
}

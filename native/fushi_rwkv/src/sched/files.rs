// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 状态快照与检查点在磁盘上的布局（文件名与元数据格式沿用搬进内核之前的 Dart 实现，已有文件照样命中）：
//!
//! - 主快照 `rwkv-<profile>-small-int4.snap`，元数据 `<主快照>.json`，写入途中 `<主快照>.tmp`；
//! - 检查点 `rwkv-<profile>-small-int4.cp-<lastAt>.snap`（+ `.json`）；
//! - 元数据 `{"v":1,"count":<行数>,"maxRowId":<最大 rowid>,"lastAt":<最晚评分时刻或 null>}`。

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// 日志表的指纹：行数与最大 rowid。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Print {
    pub count: i64,
    pub max_row_id: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Meta {
    pub print: Print,
    pub last_at: Option<i64>,
}

/// 磁盘上的一份状态快照（主快照或检查点）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub snap: PathBuf,
    pub meta: PathBuf,
    pub print: Print,
    pub last_at: Option<i64>,
}

/// 快照文件名里的模型键（沿用小模型 + int4 时的旧名）。
const MODEL_KEY: &str = "small-int4";
/// 已移除的大模型留下的快照。
const RETIRED_MODEL_KEY: &str = "large-int8";
const CHECKPOINT_TAG: &str = ".cp-";

pub struct Layout {
    pub dir: PathBuf,
    profile: String,
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

impl Layout {
    pub fn new(dir: PathBuf, profile: String) -> Self {
        Self { dir, profile }
    }

    fn stem(&self, model_key: &str) -> String {
        format!("rwkv-{}-{model_key}", self.profile)
    }

    pub fn snapshot(&self) -> PathBuf {
        self.dir.join(format!("{}.snap", self.stem(MODEL_KEY)))
    }

    pub fn meta(&self) -> PathBuf {
        with_suffix(&self.snapshot(), ".json")
    }

    pub fn tmp(&self) -> PathBuf {
        with_suffix(&self.snapshot(), ".tmp")
    }

    pub fn retired(&self) -> [PathBuf; 2] {
        let snap = self
            .dir
            .join(format!("{}.snap", self.stem(RETIRED_MODEL_KEY)));
        let meta = with_suffix(&snap, ".json");
        [snap, meta]
    }

    pub fn checkpoint(&self, last_at: i64) -> PathBuf {
        self.dir.join(format!(
            "{}{CHECKPOINT_TAG}{last_at}.snap",
            self.stem(MODEL_KEY)
        ))
    }

    /// 本 profile 的检查点文件（`.snap`），不保证顺序。
    pub fn checkpoint_files(&self) -> std::io::Result<Vec<PathBuf>> {
        if !self.dir.exists() {
            return Ok(Vec::new());
        }
        let prefix = format!("{}{CHECKPOINT_TAG}", self.stem(MODEL_KEY));
        let mut out = Vec::new();
        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if entry.file_type()?.is_file() && name.starts_with(&prefix) && name.ends_with(".snap")
            {
                out.push(entry.path());
            }
        }
        Ok(out)
    }
}

pub fn meta_of(snap: &Path) -> PathBuf {
    with_suffix(snap, ".json")
}

pub fn remove_if_exists(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

pub fn write_meta(path: &Path, print: Print, last_at: Option<i64>) -> std::io::Result<()> {
    let last_at = last_at.map_or_else(|| "null".to_owned(), |v| v.to_string());
    let text = format!(
        "{{\"v\":1,\"count\":{},\"maxRowId\":{},\"lastAt\":{last_at}}}",
        print.count, print.max_row_id
    );
    let mut file = fs::File::create(path)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()
}

/// 元数据文件解析出的对象（只认顶层的整数 / null，其余值只跳过）。
pub struct MetaObject(Vec<(String, Value)>);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Value {
    Int(i64),
    Number(f64),
    Null,
    Other,
}

impl MetaObject {
    pub fn read(path: &Path) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let mut p = Parser {
            bytes: text.as_bytes(),
            at: 0,
        };
        p.space();
        if p.peek() != Some(b'{') {
            return Err("snapshot metadata is not a JSON object".to_owned());
        }
        p.at += 1;
        let mut fields = Vec::new();
        p.space();
        if p.peek() == Some(b'}') {
            p.at += 1;
        } else {
            loop {
                p.space();
                let key = p.string()?;
                p.space();
                p.expect(b':')?;
                let value = p.value()?;
                fields.push((key, value));
                p.space();
                match p.next() {
                    Some(b',') => continue,
                    Some(b'}') => break,
                    _ => return Err(p.error("expected ',' or '}'")),
                }
            }
        }
        p.space();
        if p.at != p.bytes.len() {
            return Err(p.error("trailing characters"));
        }
        Ok(Self(fields))
    }

    fn get(&self, key: &str) -> Option<Value> {
        // 重复的键取最后一个（与 Dart 的 jsonDecode 一致）。
        self.0.iter().rev().find(|(k, _)| k == key).map(|(_, v)| *v)
    }

    /// `v` 是不是 1。
    pub fn is_v1(&self) -> bool {
        match self.get("v") {
            Some(Value::Int(1)) => true,
            Some(Value::Number(v)) => v == 1.0,
            _ => false,
        }
    }

    pub fn int(&self, key: &str) -> Result<i64, String> {
        match self.get(key) {
            Some(Value::Int(v)) => Ok(v),
            _ => Err(format!("snapshot metadata: \"{key}\" is not an integer")),
        }
    }

    pub fn opt_int(&self, key: &str) -> Result<Option<i64>, String> {
        match self.get(key) {
            Some(Value::Int(v)) => Ok(Some(v)),
            Some(Value::Null) | None => Ok(None),
            _ => Err(format!(
                "snapshot metadata: \"{key}\" is not an integer or null"
            )),
        }
    }

    pub fn meta(&self) -> Result<Meta, String> {
        Ok(Meta {
            print: Print {
                count: self.int("count")?,
                max_row_id: self.int("maxRowId")?,
            },
            last_at: self.opt_int("lastAt")?,
        })
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn error(&self, what: &str) -> String {
        format!("snapshot metadata: {what} at byte {}", self.at)
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let b = self.peek();
        self.at += usize::from(b.is_some());
        b
    }

    fn space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        if self.next() == Some(byte) {
            Ok(())
        } else {
            Err(self.error(&format!("expected '{}'", byte as char)))
        }
    }

    /// 字符串（转义只跳过、不还原：键名里没有转义）。
    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let start = self.at;
        loop {
            match self.next() {
                Some(b'"') => break,
                Some(b'\\') => {
                    self.next();
                }
                Some(_) => {}
                None => return Err(self.error("unterminated string")),
            }
        }
        Ok(String::from_utf8_lossy(&self.bytes[start..self.at - 1]).into_owned())
    }

    fn literal(&mut self, word: &str) -> Result<(), String> {
        if self.bytes[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Ok(())
        } else {
            Err(self.error("unexpected token"))
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        self.space();
        match self.peek() {
            Some(b'"') => self.string().map(|_| Value::Other),
            Some(b'n') => self.literal("null").map(|()| Value::Null),
            Some(b't') => self.literal("true").map(|()| Value::Other),
            Some(b'f') => self.literal("false").map(|()| Value::Other),
            Some(b'[') => self.nested(b']'),
            Some(b'{') => self.nested(b'}'),
            Some(b'-' | b'0'..=b'9') => {
                let start = self.at;
                while matches!(
                    self.peek(),
                    Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                ) {
                    self.at += 1;
                }
                let text = std::str::from_utf8(&self.bytes[start..self.at]).unwrap_or("");
                if let Ok(v) = text.parse::<i64>() {
                    Ok(Value::Int(v))
                } else {
                    text.parse::<f64>()
                        .map(Value::Number)
                        .map_err(|_| self.error("bad number"))
                }
            }
            _ => Err(self.error("unexpected token")),
        }
    }

    /// 跳过一个数组 / 对象。
    fn nested(&mut self, close: u8) -> Result<Value, String> {
        self.at += 1;
        loop {
            self.space();
            match self.peek() {
                Some(b) if b == close => {
                    self.at += 1;
                    return Ok(Value::Other);
                }
                Some(b',' | b':') => self.at += 1,
                Some(_) => {
                    self.value()?;
                }
                None => return Err(self.error("unterminated value")),
            }
        }
    }
}

/// 读一份快照的元数据。两个文件有一个不在 → `Ok(None)`；`v` 不是 1 → `Ok(None)`；读不了 / 格式不对 → `Err`。
pub fn read_checkpoint(snap: &Path, meta: &Path) -> Result<Option<Checkpoint>, String> {
    if !snap.exists() || !meta.exists() {
        return Ok(None);
    }
    let object = MetaObject::read(meta)?;
    if !object.is_v1() {
        return Ok(None);
    }
    let parsed = object.meta()?;
    Ok(Some(Checkpoint {
        snap: snap.to_owned(),
        meta: meta.to_owned(),
        print: parsed.print,
        last_at: parsed.last_at,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn meta_round_trip_matches_the_dart_layout() {
        let dir = std::env::temp_dir().join(format!("frwkv-sched-meta-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("m.json");
        write_meta(
            &path,
            Print {
                count: 12,
                max_row_id: 34,
            },
            None,
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            r#"{"v":1,"count":12,"maxRowId":34,"lastAt":null}"#
        );
        let meta = MetaObject::read(&path).unwrap();
        assert!(meta.is_v1());
        assert_eq!(
            meta.meta().unwrap(),
            Meta {
                print: Print {
                    count: 12,
                    max_row_id: 34
                },
                last_at: None
            }
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn meta_parsing_edge_cases() {
        let ok = MetaObject::parse(
            r#" { "x": [1, {"a": "b\"c"}], "v": 1.0, "count": 5, "maxRowId": 9, "lastAt": -3 } "#,
        )
        .unwrap();
        assert!(ok.is_v1());
        assert_eq!(ok.meta().unwrap().last_at, Some(-3));
        assert!(!MetaObject::parse(r#"{"v":2}"#).unwrap().is_v1());
        assert!(
            MetaObject::parse(r#"{"v":1,"count":"5"}"#)
                .unwrap()
                .meta()
                .is_err()
        );
        assert!(
            MetaObject::parse(r#"{"v":1,"count":5.5,"maxRowId":1}"#)
                .unwrap()
                .meta()
                .is_err()
        );
        assert!(MetaObject::parse("[1]").is_err());
        assert!(MetaObject::parse(r#"{"v":1"#).is_err());
        assert!(MetaObject::parse("not json").is_err());
    }
}

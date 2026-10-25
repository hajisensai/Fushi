//! 「行头 + 逐字时间」一族的明文格式：
//!
//! | 格式 | 行 | 音节 | 时间基准 |
//! |---|---|---|---|
//! | Lyricify Syllable `.lys` | `[属性]` | `字(起,长)` | 绝对 |
//! | QRC 明文（`.qrc` 解密后 / XML 包装） | `[起,长]` | `字(起,长)` | 绝对 |
//! | YRC（网易云） | `[起,长]` | `(起,长,0)字` | 绝对 |
//! | KRC 明文（酷狗，解密见 [decrypt_krc]） | `[起,长]` | `<偏移,长,0>字` | 相对行首 |
//!
//! LYS 属性：0–2 主唱（未设 / 左 / 右），3–5 和声（未设 / 左 / 右），6–8 同 0–2；左 = `v1`、
//! 右 = `v2`。KRC 的 `[language:base64]` 带翻译（type 1）与罗马音（type 0），按行序挂上。

use std::io::Read;

use super::json::{self, Json};
use super::markup::unescape;
use super::model::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flavor {
    Lys,
    Qrc,
    Yrc,
    Krc,
}

impl Flavor {
    pub fn format_name(self) -> &'static str {
        match self {
            Flavor::Lys => "lys",
            Flavor::Qrc => "qrc",
            Flavor::Yrc => "yrc",
            Flavor::Krc => "krc",
        }
    }
}

fn parse_pair(s: &str) -> Option<(i64, i64)> {
    let mut it = s.split(',').map(|p| p.trim().parse::<i64>().ok());
    let a = it.next()??;
    let b = it.next()??;
    Some((a, b))
}

/// 嗅探明文里是哪一种（不认识返回 None）。
pub fn sniff(text: &str) -> Option<Flavor> {
    for raw in text.lines().take(200) {
        let l = raw.trim();
        let Some(r) = l.strip_prefix('[') else { continue };
        let Some(end) = r.find(']') else { continue };
        let head = &r[..end];
        let body = &r[end + 1..];
        if head.len() == 1 && head.as_bytes()[0].is_ascii_digit() && body.contains('(') && body.ends_with(')') {
            return Some(Flavor::Lys);
        }
        if parse_pair(head).is_none() {
            continue;
        }
        if body.starts_with('<') {
            return Some(Flavor::Krc);
        }
        if body.starts_with('(') {
            return Some(Flavor::Yrc);
        }
        if body.ends_with(')') {
            return Some(Flavor::Qrc);
        }
    }
    None
}

/// QRC 的 XML 包装（`<Lyric_1 LyricType="1" LyricContent="..."/>`）里取正文。
pub fn unwrap_qrc_xml(text: &str) -> Option<String> {
    let i = text.find("LyricContent=\"")?;
    let rest = &text[i + "LyricContent=\"".len()..];
    let end = rest.find("\"/>").or_else(|| rest.rfind('"'))?;
    Some(unescape(&rest[..end]))
}

pub fn parse(text: &str, flavor: Flavor, duration_ms: Option<i64>) -> Timeline {
    let mut t = Timeline::new(flavor.format_name(), TimingQuality::Syllable);
    let mut krc_lang: Option<Json> = None;
    for raw in text.lines() {
        let l = raw.trim();
        let Some(r) = l.strip_prefix('[') else { continue };
        let Some(end) = r.find(']') else { continue };
        let head = &r[..end];
        let body = &r[end + 1..];
        if let Some((k, v)) = head.split_once(':') {
            match k.trim() {
                "ti" if !v.trim().is_empty() => t.meta.title = Some(v.trim().to_owned()),
                "ar" if !v.trim().is_empty() => t.meta.artist = Some(v.trim().to_owned()),
                "language" if flavor == Flavor::Krc => {
                    krc_lang = data_encoding::BASE64
                        .decode(v.trim().as_bytes())
                        .ok()
                        .and_then(|b| String::from_utf8(b).ok())
                        .and_then(|s| json::parse(&s));
                }
                _ => {}
            }
            continue;
        }
        let line = match flavor {
            Flavor::Lys => {
                let Ok(prop) = head.trim().parse::<u32>() else { continue };
                let mut line = Line::default();
                line.syllables = text_then_time(body, 0);
                if prop >= 3 && prop <= 5 {
                    line.role = Role::Background;
                }
                match prop % 3 {
                    1 => line.agent = Some(t.agent_index("v1", AgentKind::Person)),
                    2 => line.agent = Some(t.agent_index("v2", AgentKind::Person)),
                    _ => {}
                }
                line
            }
            _ => {
                let Some((ls, ld)) = parse_pair(head) else { continue };
                let mut line = Line { start_ms: ls, end_ms: ls + ld, ..Line::default() };
                line.syllables = match flavor {
                    Flavor::Qrc => text_then_time(body, 0),
                    Flavor::Yrc => time_then_text(body, '(', ')', 0),
                    Flavor::Krc => time_then_text(body, '<', '>', ls),
                    Flavor::Lys => unreachable!(),
                };
                line
            }
        };
        if line.syllables.is_empty() {
            continue;
        }
        let mut line = line;
        if line.start_ms == 0 && line.end_ms == 0 {
            line.start_ms = line.syllables.first().map(|s| s.start_ms).unwrap_or(0);
            line.end_ms = line.syllables.iter().map(|s| s.end_ms).max().unwrap_or(0);
        }
        t.lines.push(line);
    }
    if let Some(lang) = krc_lang {
        apply_krc_language(&mut t, &lang);
    }
    t.finalize(duration_ms);
    t
}

/// `字(起,长)字(起,长)`：时间跟在文本后面。
fn text_then_time(body: &str, base: i64) -> Vec<Syllable> {
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(open) = find_time_group(rest, '(', ')') {
        let (o, c, start, dur) = open;
        let text = &rest[..o];
        if !text.is_empty() {
            out.push(Syllable::new(text, base + start, base + start + dur));
        }
        rest = &rest[c + 1..];
    }
    out
}

/// `(起,长,0)字` / `<偏移,长,0>字`：时间在文本前面。
fn time_then_text(body: &str, open_c: char, close_c: char, base: i64) -> Vec<Syllable> {
    let mut out: Vec<Syllable> = Vec::new();
    let mut rest = body;
    let mut pending: Option<(i64, i64)> = None;
    loop {
        let next = find_time_group(rest, open_c, close_c);
        let text_end = next.map(|g| g.0).unwrap_or(rest.len());
        let text = &rest[..text_end];
        if let Some((s, d)) = pending.take() {
            if !text.is_empty() {
                out.push(Syllable::new(text, base + s, base + s + d));
            }
        }
        match next {
            Some((_, c, s, d)) => {
                pending = Some((s, d));
                rest = &rest[c + 1..];
            }
            None => break,
        }
    }
    out
}

/// 找下一个形如 `(a,b)` / `(a,b,c)` 的时间组：返回 (开括号位置, 闭括号位置, a, b)。
/// 括号里不是数字的（歌词正文里的普通括号）跳过。
fn find_time_group(s: &str, open_c: char, close_c: char) -> Option<(usize, usize, i64, i64)> {
    let mut from = 0;
    while let Some(o) = s[from..].find(open_c).map(|p| p + from) {
        if let Some(c) = s[o + 1..].find(close_c).map(|p| p + o + 1) {
            let inner = &s[o + 1..c];
            if inner.chars().all(|ch| ch.is_ascii_digit() || ch == ',' || ch == '-' || ch == ' ') {
                if let Some((a, b)) = parse_pair(inner) {
                    return Some((o, c, a, b));
                }
            }
        }
        from = o + open_c.len_utf8();
    }
    None
}

fn apply_krc_language(t: &mut Timeline, lang: &Json) {
    let main_idx: Vec<usize> = (0..t.lines.len()).filter(|&i| t.lines[i].role == Role::Main).collect();
    for item in lang.get("content").map(Json::as_arr).unwrap_or(&[]) {
        let ty = item.get("type").and_then(Json::as_f64).unwrap_or(-1.0) as i64;
        let rows = item.get("lyricContent").map(Json::as_arr).unwrap_or(&[]);
        for (row, &li) in rows.iter().zip(main_idx.iter()) {
            let parts: Vec<&str> = row.as_arr().iter().filter_map(Json::as_str).collect();
            match ty {
                0 => {
                    let r = parts.iter().map(|p| p.trim()).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ");
                    if !r.is_empty() {
                        t.lines[li].romanization = Some(r);
                    }
                }
                1 => {
                    let tr = parts.concat();
                    t.lines[li].add_translation("und", &tr);
                }
                _ => {}
            }
        }
    }
}

/// 酷狗 KRC 加密：`krc1` 头 + 16 字节密钥循环异或 + zlib。
const KRC_KEY: [u8; 16] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];

pub fn is_encrypted_krc(b: &[u8]) -> bool {
    b.starts_with(b"krc1")
}

pub fn decrypt_krc(b: &[u8]) -> Option<Vec<u8>> {
    let body = b.strip_prefix(b"krc1")?;
    let xored: Vec<u8> = body.iter().enumerate().map(|(i, &x)| x ^ KRC_KEY[i % 16]).collect();
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(&xored[..]).read_to_end(&mut out).ok()?;
    Some(out)
}

/// 测试 / 往返用：把明文 KRC 加密成 `krc1` 文件。
pub fn encrypt_krc(plain: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(plain).unwrap();
    let packed = z.finish().unwrap();
    let mut out = b"krc1".to_vec();
    out.extend(packed.iter().enumerate().map(|(i, &x)| x ^ KRC_KEY[i % 16]));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lys_left_right_and_background() {
        let text = "[ti:T]\n[1]Hel(1000,500)lo (1500,200)\n[5](ah)(1600,400)\n[2]world(2000,800)";
        assert_eq!(sniff(text), Some(Flavor::Lys));
        let t = parse(text, Flavor::Lys, None);
        assert_eq!(t.lines.len(), 3);
        assert_eq!(t.lines[0].text(), "Hello ");
        assert_eq!(t.agents[t.lines[0].agent.unwrap()].id, "v1");
        assert_eq!(t.lines[1].role, Role::Background);
        assert_eq!(t.lines[1].text(), "(ah)");
        assert_eq!(t.agents[t.lines[2].agent.unwrap()].id, "v2");
    }

    #[test]
    fn qrc_yrc_krc() {
        let q = "[1000,1000]夜(1000,300)に(1300,700)";
        assert_eq!(sniff(q), Some(Flavor::Qrc));
        let t = parse(q, Flavor::Qrc, None);
        assert_eq!(t.lines[0].syllables[1].start_ms, 1300);

        let y = "{\"t\":0,\"c\":[{\"tx\":\"作词: \"}]}\n[1000,1000](1000,300,0)夜(1300,700,0)に";
        assert_eq!(sniff(y), Some(Flavor::Yrc));
        let t = parse(y, Flavor::Yrc, None);
        assert_eq!(t.lines.len(), 1);
        assert_eq!(t.lines[0].text(), "夜に");
        assert_eq!(t.lines[0].syllables[1].end_ms, 2000);

        let k = "[language:eyJjb250ZW50IjpbeyJ0eXBlIjoxLCJseXJpY0NvbnRlbnQiOltbIuWknCJdXX1dfQ==]\n[1000,1000]<0,300,0>夜<300,700,0>に";
        assert_eq!(sniff(k), Some(Flavor::Krc));
        let t = parse(k, Flavor::Krc, None);
        assert_eq!(t.lines[0].syllables[1].start_ms, 1300);
        assert_eq!(t.lines[0].translations[0].1, "夜");
    }

    #[test]
    fn krc_encryption_round_trip() {
        let enc = encrypt_krc("[1000,500]<0,500,0>a".as_bytes());
        assert!(is_encrypted_krc(&enc));
        assert_eq!(decrypt_krc(&enc).unwrap(), b"[1000,500]<0,500,0>a");
    }

    #[test]
    fn plain_parentheses_in_text_are_kept() {
        let t = parse("[1000,1000]A(b)(1000,500)c(1500,500)", Flavor::Qrc, None);
        assert_eq!(t.lines[0].syllables[0].text, "A(b)");
    }
}

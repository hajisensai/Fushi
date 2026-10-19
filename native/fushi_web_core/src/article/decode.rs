//! 整页原始字节 → 文本。
//!
//! 两条来源的字节性质不同：WebView 取回的 `outerHTML` 已是 Unicode（Dart 编成 UTF-8 交进来），
//! 但页面里 `<meta charset=gb18030>` 原样还在；直接 HTTP 取回的是站点原编码。所以判据顺序是
//! BOM → **整段是合法 UTF-8 就是 UTF-8**（不信 meta）→ meta / XML 声明里的 charset → 都没有时
//! 在 Shift_JIS 与 GB18030 里挑解码错误更少的那个（日 / 中文小说站的两大旧编码）。

use encoding_rs::{Encoding, GB18030, SHIFT_JIS, UTF_8};

/// 解码结果：文本 + 实际使用的编码名（WHATWG 名，小写）。
pub(crate) struct Decoded {
    pub text: String,
    pub charset: &'static str,
}

pub(crate) fn decode_html(bytes: &[u8]) -> Decoded {
    if let Some((encoding, bom_len)) = Encoding::for_bom(bytes) {
        let (text, _) = encoding.decode_without_bom_handling(&bytes[bom_len..]);
        return Decoded {
            text: text.into_owned(),
            charset: canonical_name(encoding),
        };
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Decoded {
            text: text.to_owned(),
            charset: "utf-8",
        };
    }
    if let Some(encoding) = sniff_declared(bytes) {
        // UTF-16 声明在 ASCII 兼容的字节流里是假话（HTML 标准同样忽略它）。
        if encoding != UTF_8 && encoding.is_ascii_compatible() {
            let (text, _) = encoding.decode_without_bom_handling(bytes);
            return Decoded {
                text: text.into_owned(),
                charset: canonical_name(encoding),
            };
        }
    }
    let candidates = [SHIFT_JIS, GB18030];
    let mut best: Option<(usize, String, &'static Encoding)> = None;
    for encoding in candidates {
        let (text, _) = encoding.decode_without_bom_handling(bytes);
        let errors = text.chars().filter(|c| *c == '\u{FFFD}').count();
        if best.as_ref().is_none_or(|(e, _, _)| errors < *e) {
            best = Some((errors, text.into_owned(), encoding));
        }
    }
    let (_, text, encoding) = best.expect("two candidates");
    Decoded {
        text,
        charset: canonical_name(encoding),
    }
}

fn canonical_name(encoding: &'static Encoding) -> &'static str {
    match encoding.name() {
        "UTF-8" => "utf-8",
        "Shift_JIS" => "shift_jis",
        "gb18030" => "gb18030",
        "GBK" => "gbk",
        "EUC-JP" => "euc-jp",
        "Big5" => "big5",
        "EUC-KR" => "euc-kr",
        "UTF-16LE" => "utf-16le",
        "UTF-16BE" => "utf-16be",
        "windows-1252" => "windows-1252",
        _ => "other",
    }
}

/// 在前 4 KB 里找 `charset=…`（`<meta charset>` / `http-equiv` / XML 声明的 `encoding=`）。
fn sniff_declared(bytes: &[u8]) -> Option<&'static Encoding> {
    let head = &bytes[..bytes.len().min(4096)];
    let lower: Vec<u8> = head.iter().map(|b| b.to_ascii_lowercase()).collect();
    for needle in [&b"charset="[..], &b"encoding="[..]] {
        let mut from = 0;
        while let Some(pos) = find(&lower[from..], needle) {
            let start = from + pos + needle.len();
            let label: Vec<u8> = lower[start..]
                .iter()
                .copied()
                .skip_while(|b| *b == b'"' || *b == b'\'' || *b == b' ')
                .take_while(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
                .collect();
            if let Some(encoding) = Encoding::for_label(&label) {
                return Some(encoding);
            }
            from = start;
        }
    }
    None
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_wins_over_stale_meta() {
        let html = "<meta charset=\"gb18030\"><p>夕阳西下</p>";
        let d = decode_html(html.as_bytes());
        assert_eq!(d.charset, "utf-8");
        assert!(d.text.contains("夕阳西下"));
    }

    #[test]
    fn declared_gbk_is_used_for_invalid_utf8() {
        let (bytes, _, _) = GB18030.encode("<meta charset=gbk><p>何以笙箫默</p>");
        let d = decode_html(&bytes);
        assert_eq!(d.charset, "gbk");
        assert!(d.text.contains("何以笙箫默"));
    }

    #[test]
    fn undeclared_shift_jis_is_guessed() {
        let (bytes, _, _) = SHIFT_JIS.encode("<p>俺は34歳住所不定無職。</p>");
        let d = decode_html(&bytes);
        assert_eq!(d.charset, "shift_jis");
        assert!(d.text.contains("住所不定無職"));
    }

    #[test]
    fn bom_is_honoured() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice("<p>x</p>".as_bytes());
        let d = decode_html(&bytes);
        assert_eq!(d.charset, "utf-8");
        assert_eq!(d.text, "<p>x</p>");
    }
}

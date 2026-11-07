//! ID3 「ISO-8859-1」文本里实际装着本地多字节编码时的探测与回退。
//!
//! ID3v1 只有 Latin-1；ID3v2 的 `encoding = 0` 帧按规范也是 Latin-1。但大量日 / 中文旧
//! 打标工具把 Shift_JIS / EUC-JP / GBK / Big5 原始字节直接塞进这些帧，lofty（以及 ffprobe）
//! 按规范逐字节映成 U+0000..U+00FF，曲库里就出现 `Çà¤¤Í«¤Î¥Ê¥¤¥È` 这种乱码（EUC-JP 的
//! 「…のナイト」）。Latin-1 解码逐字节可逆（`char as u8`），所以能无损还原出原始字节重新判。
//!
//! 判据（**整份标签一起判**：打标工具对同一文件只用一种编码，多字段合起来证据更足）：
//!
//! 1. 参与判定的字符串必须全部落在 U+0000..U+00FF（即确实是逐字节 Latin-1 解出来的），
//!    且至少一个含 ≥0x80 的字节；否则什么都不动。
//! 2. 至少一个字符串的字节**不像真 Latin-1 文本**（[latin1_plausible]）。真 Latin-1
//!    文本的高位字节是零散的重音字母（`Café`、`Pokémon`、`Größe`）：单个出现，或至多两个
//!    字母相邻；C1 控制区 0x80–0x9F 只可能以 CP1252 标点（`’` `“` `…`）单独出现。双字节
//!    编码的汉字 / 假名成对、成串出现，必然破坏这个形状。
//! 3. 候选编码 Shift_JIS → GBK → EUC-JP → Big5 各自**零错误**解码全部字符串，且解出的
//!    非 ASCII 字符只能是假名 / 汉字 / 全角标点 / 半角片假名 / 常见符号（PUA、残留的
//!    Latin-1 字母、控制符一律淘汰该候选）。剩下的按 [score_char] 计分取最高，同分按上面
//!    的顺序。假名只在日文编码里加权：EUC-JP 与 GB2312 的假名码位重合，靠「有没有假名」
//!    区分日文 EUC-JP 与中文 GBK；GBK 里落在 GB2312 区外（扩展区）的字只给低分，使 Shift_JIS
//!    与 Big5 的字节不会被 GBK 的宽松码位抢走。
//!
//! 字节层面固有、无法区分的残余：全汉字、无假名的 EUC-JP 与 GB2312 字节完全同形；全落在
//! 常用区的 Big5 与 GBK 同形 —— 同分按顺序取 GBK。

use encoding_rs::{BIG5, EUC_JP, Encoding, GBK, SHIFT_JIS};

/// 候选顺序即同分时的优先级（见模块文档）。
const CANDIDATES: [&Encoding; 4] = [SHIFT_JIS, GBK, EUC_JP, BIG5];

/// CP1252 在 0x80–0x9F 里真会出现在标签文本中的标点：`€ … ‘ ’ “ ” – — ™`。
const CP1252_PUNCT: [u8; 9] = [0x80, 0x85, 0x91, 0x92, 0x93, 0x94, 0x96, 0x97, 0x99];

/// 逐字节 Latin-1 解码的逆过程。含 U+00FF 以上字符（说明不是 Latin-1 解出来的）返回 None。
fn latin1_bytes(s: &str) -> Option<Vec<u8>> {
    s.chars().map(|c| u8::try_from(u32::from(c)).ok()).collect()
}

fn is_latin1_letter(b: u8) -> bool {
    b >= 0xC0 && b != 0xD7 && b != 0xF7
}

/// 这串字节按 Latin-1（含 CP1252 标点）读是否像真实文本（见模块文档判据 2）。
pub fn latin1_plausible(bytes: &[u8]) -> bool {
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] < 0x80 {
            i += 1;
            continue;
        }
        let start = i;
        while i < bytes.len() && bytes[i] >= 0x80 {
            i += 1;
        }
        let run = &bytes[start..i];
        let ok = match run.len() {
            1 => run[0] >= 0xA0 || CP1252_PUNCT.contains(&run[0]),
            2 => run.iter().all(|&b| is_latin1_letter(b)),
            _ => false,
        };
        if !ok {
            return false;
        }
    }
    true
}

/// 一个解码后字符的分值；`None` = 这种字符不会出现在该编码的正常文本里，淘汰候选。
fn score_char(enc: &'static Encoding, c: char) -> Option<u32> {
    let japanese = enc == SHIFT_JIS || enc == EUC_JP;
    Some(match u32::from(c) {
        0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F => return None,
        0x00..=0x7F => 0,
        // 平假名 / 片假名 / 片假名音标扩展。
        0x3041..=0x30FF | 0x31F0..=0x31FF => {
            if japanese {
                4
            } else {
                2
            }
        }
        // 汉字（扩展 A、基本区、兼容区）。
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF => {
            if enc == GBK && !gbk_in_gb2312(c) {
                1
            } else {
                2
            }
        }
        // CJK 标点、全角 ASCII / 全角符号。
        0x3000..=0x303F | 0xFF01..=0xFF60 | 0xFFE0..=0xFFE6 => 2,
        // 半角片假名（Shift_JIS 单字节区）。
        0xFF61..=0xFF9F => 1,
        // 这些编码字符集都收录的常见符号：希腊 / 西里尔字母、一般标点、字母式符号、数字
        // 形式、箭头、数学、带圈数字、制表符、几何图形、杂项符号（★ ♪）、CJK 带圈 / 单位。
        0x0391..=0x03C9
        | 0x0401..=0x0451
        | 0x2010..=0x203B
        | 0x2100..=0x2199
        | 0x21D2..=0x21D4
        | 0x2200..=0x22FF
        | 0x2460..=0x24FF
        | 0x2500..=0x257F
        | 0x25A0..=0x25FF
        | 0x2600..=0x266F
        | 0x3200..=0x33FF
        | 0xA7
        | 0xA8
        | 0xB0
        | 0xB1
        | 0xB4
        | 0xB6
        | 0xD7
        | 0xF7 => 0,
        _ => return None,
    })
}

/// GBK 解出的字是否落在 GB2312 常用区（两字节都 ≥ 0xA1）。
fn gbk_in_gb2312(c: char) -> bool {
    let mut buf = [0u8; 4];
    let (bytes, _, had_errors) = GBK.encode(c.encode_utf8(&mut buf));
    !had_errors && bytes.len() == 2 && bytes[0] >= 0xA1 && bytes[1] >= 0xA1
}

/// 整份标签的字符串里探测出的本地编码；不需要（或不能可靠）重解时返回 None。
pub fn detect<'a, I>(values: I) -> Option<&'static Encoding>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut raw: Vec<Vec<u8>> = Vec::new();
    for v in values {
        // 有任何一个字段不是逐字节 Latin-1 解出来的，说明这份标签本身是 Unicode 帧，不动。
        let bytes = latin1_bytes(v)?;
        if bytes.iter().any(|&b| b >= 0x80) {
            raw.push(bytes);
        }
    }
    if raw.is_empty() || raw.iter().all(|b| latin1_plausible(b)) {
        return None;
    }
    let mut best: Option<(&'static Encoding, u32)> = None;
    'candidates: for enc in CANDIDATES {
        let mut total = 0u32;
        for bytes in &raw {
            let (text, had_errors) = enc.decode_without_bom_handling(bytes);
            if had_errors {
                continue 'candidates;
            }
            for c in text.chars() {
                match score_char(enc, c) {
                    Some(s) => total += s,
                    None => continue 'candidates,
                }
            }
        }
        if total > 0 && best.is_none_or(|(_, s)| total > s) {
            best = Some((enc, total));
        }
    }
    best.map(|(enc, _)| enc)
}

/// 把一个 Latin-1 解出来的字符串按 [enc] 重解；不是 Latin-1 范围的串原样返回。
pub fn redecode(s: &str, enc: &'static Encoding) -> String {
    match latin1_bytes(s) {
        Some(bytes) => enc.decode_without_bom_handling(&bytes).0.into_owned(),
        None => s.to_owned(),
    }
}

/// 对一组同源字段（同一份 ID3 标签）就地探测并重解。返回探测到的编码名。
pub fn repair_in_place(values: &mut [&mut String]) -> Option<&'static str> {
    let enc = detect(values.iter().map(|s| s.as_str()))?;
    for v in values.iter_mut() {
        **v = redecode(v, enc);
    }
    Some(enc.name())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 把原始字节按 lofty 的方式（逐字节）解成 Latin-1 字符串。
    fn as_latin1(bytes: &[u8]) -> String {
        bytes.iter().map(|&b| b as char).collect()
    }

    fn encoded(enc: &'static Encoding, s: &str) -> String {
        let (b, _, had_errors) = enc.encode(s);
        assert!(!had_errors, "{s} not encodable in {}", enc.name());
        as_latin1(&b)
    }

    fn repair(values: &[String]) -> (Option<&'static str>, Vec<String>) {
        let mut owned: Vec<String> = values.to_vec();
        let mut refs: Vec<&mut String> = owned.iter_mut().collect();
        let enc = repair_in_place(&mut refs);
        (enc, owned)
    }

    #[test]
    fn shift_jis_tags_are_recovered() {
        let vals = vec![
            encoded(SHIFT_JIS, "夜に駆ける"),
            encoded(SHIFT_JIS, "YOASOBI"),
            encoded(SHIFT_JIS, "THE BOOK"),
        ];
        let (enc, out) = repair(&vals);
        assert_eq!(enc, Some("Shift_JIS"));
        assert_eq!(out, vec!["夜に駆ける", "YOASOBI", "THE BOOK"]);
    }

    #[test]
    fn shift_jis_katakana_with_ascii_trail_bytes() {
        // ア = 83 41、イ = 83 43：尾字节落在 ASCII 区。
        let (enc, out) = repair(&[encoded(SHIFT_JIS, "act.2 アイドル")]);
        assert_eq!(enc, Some("Shift_JIS"));
        assert_eq!(out, vec!["act.2 アイドル"]);
    }

    #[test]
    fn shift_jis_all_kanji_is_not_taken_by_gbk() {
        let (enc, out) = repair(&[
            encoded(SHIFT_JIS, "東京事変"),
            encoded(SHIFT_JIS, "米津玄師"),
        ]);
        assert_eq!(enc, Some("Shift_JIS"));
        assert_eq!(out, vec!["東京事変", "米津玄師"]);
    }

    #[test]
    fn euc_jp_from_the_feedback_screenshot() {
        // 反馈截图里的原样乱码：`act.2 Çà¤¤Í«¤Î¥Ê¥¤¥È`。
        let garbled = "act.2 Çà¤¤Í«¤Î¥Ê¥¤¥È".to_owned();
        let bytes = latin1_bytes(&garbled).unwrap();
        let (expected, had_errors) = EUC_JP.decode_without_bom_handling(&bytes);
        assert!(!had_errors);
        assert!(expected.ends_with("のナイト"), "{expected}");
        let expected = expected.into_owned();
        let (enc, out) = repair(&[garbled]);
        assert_eq!(enc, Some("EUC-JP"));
        assert_eq!(out, vec![expected]);
    }

    #[test]
    fn euc_jp_with_kana_beats_gbk() {
        let (enc, out) = repair(&[encoded(EUC_JP, "眠れない夜のナイト")]);
        assert_eq!(enc, Some("EUC-JP"));
        assert_eq!(out, vec!["眠れない夜のナイト"]);
    }

    #[test]
    fn gbk_chinese_is_recovered() {
        let (enc, out) = repair(&[encoded(GBK, "晴天"), encoded(GBK, "周杰伦")]);
        assert_eq!(enc, Some("GBK"));
        assert_eq!(out, vec!["晴天", "周杰伦"]);
    }

    #[test]
    fn big5_with_low_trail_bytes_beats_gbk() {
        // 「周」= A9 50、「杰」= AA 4E：尾字节在 ASCII 区，GBK 只能解成扩展区字 / 符号。
        let (enc, out) = repair(&[encoded(BIG5, "周杰倫"), encoded(BIG5, "晴天")]);
        assert_eq!(enc, Some("Big5"));
        assert_eq!(out, vec!["周杰倫", "晴天"]);
    }

    #[test]
    fn real_latin1_text_is_left_alone() {
        for s in [
            "Café del Mar",
            "Pokémon",
            "Größe",
            "Beyoncé",
            "Mötley Crüe",
            "Ñandú",
            "Sigur Rós",
            "Björk",
            "Déjà vu",
            "Ça plane pour moi",
            "© 2001 Ærø",
            "½ Asleep",
            "Señorita",
        ] {
            let (enc, out) = repair(&[s.to_owned()]);
            assert_eq!(enc, None, "{s} misdetected");
            assert_eq!(out, vec![s.to_owned()]);
        }
    }

    #[test]
    fn whole_tag_of_real_latin1_is_left_alone() {
        let vals: Vec<String> = ["Pokémon Théme", "Göran Söderström", "Für Élise"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        let (enc, out) = repair(&vals);
        assert_eq!(enc, None);
        assert_eq!(out, vals);
    }

    #[test]
    fn cp1252_punctuation_is_left_alone() {
        // `Don’t` 的 0x92 按 Shift_JIS 会和 `t` 拼成一个汉字；单独出现的 CP1252 标点必须保留。
        let s = as_latin1(b"Don\x92t Stop \x93Me\x94");
        let (enc, out) = repair(std::slice::from_ref(&s));
        assert_eq!(enc, None);
        assert_eq!(out, vec![s]);
    }

    #[test]
    fn unicode_strings_are_never_touched() {
        let vals = vec!["夜に駆ける".to_owned(), "Café".to_owned()];
        let (enc, out) = repair(&vals);
        assert_eq!(enc, None);
        assert_eq!(out, vals);
    }

    #[test]
    fn ascii_only_is_untouched() {
        let (enc, _) = repair(&["FREE TALK".to_owned(), "MP3 192k".to_owned()]);
        assert_eq!(enc, None);
    }

    #[test]
    fn undecodable_garbage_stays_latin1() {
        // 三连高位字节（不像 Latin-1），但任何候选都解不干净 → 不动。
        let s = as_latin1(&[b'a', 0xFF, 0xFF, 0xFF]);
        let (enc, out) = repair(std::slice::from_ref(&s));
        assert_eq!(enc, None);
        assert_eq!(out, vec![s]);
    }
}

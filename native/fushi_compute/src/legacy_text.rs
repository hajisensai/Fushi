//! 声明为单字节 / 没声明编码的文本里实际装着本地多字节编码时的探测与回退。
//!
//! **一份源码、两个 crate 复用**：本文件只依赖 `encoding_rs`、不引用任何 `crate::` 项。
//! fushi_compute 以 `mod legacy_text` 编入（C ABI 见 `text.rs` 的 `ffc_text_legacy_decode`），
//! native/fushi_music 以 `#[path]` 编入同一个文件（曲库 ID3 乱码修复）。改判据两边一起
//! 生效；两个 crate 的 `cargo test` 都跑本文件的测试。
//!
//! 来源一，ID3：ID3v1 只有 Latin-1；ID3v2 的 `encoding = 0` 帧按规范也是 Latin-1。但大量日 / 中文旧
//! 打标工具把 Shift_JIS / EUC-JP / GBK / Big5 原始字节直接塞进这些帧，lofty（以及 ffprobe）
//! 按规范逐字节映成 U+0000..U+00FF，曲库里就出现 `Çà¤¤Í«¤Î¥Ê¥¤¥È` 这种乱码（EUC-JP 的
//! 「…のナイト」）。Latin-1 解码逐字节可逆（`char as u8`），所以能无损还原出原始字节重新判
//! （[detect] / [repair_in_place]）。
//!
//! 来源二，ZIP 条目名：通用位 11 没置时名字按规范是 CP437，实际是打包机器的本地编码（日文
//! Windows 的 Shift_JIS、中文 Windows 的 GBK）。调用方直接给原始字节（[detect_bytes] /
//! [decode_batch]），不经 Latin-1 往返。
//!
//! 判据（**整批一起判**：打标工具对同一文件、压缩工具对同一个包只用一种编码，多个字符串
//! 合起来证据更足）：
//!
//! 1. 字符串入口（[detect]）要求参与判定的字符串全部落在 U+0000..U+00FF（即确实是逐字节
//!    Latin-1 解出来的）；两个入口都要求至少一个含 ≥0x80 的字节，否则什么都不动。
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
//! 整份文档（字幕 / 歌词 / 播放列表 / 纯文本文件，[decode_document]）用同一套候选与计分，只把
//! 判据 3 的「零错误、零表外字符」放宽成按比例容错，并先挡掉「基本是 UTF-8、只坏了几处」
//! 的输入（[mostly_utf8]），再要求攒够最低分值。口径来自实测（2026-11）：40 份日文、60 份
//! 中文真实字幕的文本转成 CP932 / EUC-JP / GBK / Big5 共 154 份，正确编码的坏字符占比最高
//! 0.42%（都是没列进 [score_char] 的符号），其中 17 份按零容错会被淘汰；错误候选里 GBK 解
//! 日文字节常常零错误，仍靠计分区分。
//!
//! 整份文档另有两条**结构证据**（[DocumentAssessment::shaped_like_cjk]），挡的是单字节西文
//! 编码被候选「零错误」解成 CJK：Windows-1252 的英文 / 德文字幕里高位字节零散出现（`don’t`
//! 的 0x92、`möchte` 的 0xF6），与后一个 ASCII 字母恰好拼成 Shift_JIS / GBK 的一个合法双字节
//! 字 —— 解出的每个「汉字」都孤零零夹在 ASCII 里并贴着字母；真 CJK 正文的字成串出现。
//! Windows-1256 阿拉伯文 / TIS-620 泰文的字节大半落在 Shift_JIS 的单字节半角片假名区 ——
//! 真日文正文不会半数以上是半角片假名。[latin1_plausible] 是为短标签写的（一处 `…”` 就
//! 整份判否），整份文档不能只靠它。
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
        // CJK 标点、全角 ASCII / 全角符号；间隔号 `·`（GBK A1A4 / Big5 A150，中文人名、歌名里
        // 的常客 —— 同一对字节在 EUC-JP 里是全角逗号，分值要一样才不会被它抢走）。
        0x3000..=0x303F | 0xFF01..=0xFF60 | 0xFFE0..=0xFFE6 | 0xB7 => 2,
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
        raw.push(latin1_bytes(v)?);
    }
    detect_bytes(raw.iter().map(Vec::as_slice))
}

/// 一批原始字节串（同一来源、同一种编码）里探测出的本地编码；全是 ASCII、像真 Latin-1
/// 文本、或没有候选能零错误解开时返回 None。
pub fn detect_bytes<'a, I>(values: I) -> Option<&'static Encoding>
where
    I: IntoIterator<Item = &'a [u8]>,
{
    let raw: Vec<&[u8]> = values
        .into_iter()
        .filter(|b| b.iter().any(|&c| c >= 0x80))
        .collect();
    if raw.is_empty() || raw.iter().all(|b| latin1_plausible(b)) {
        return None;
    }
    let mut best: Option<(&'static Encoding, u32)> = None;
    'candidates: for enc in CANDIDATES {
        let mut total = 0u32;
        for &bytes in &raw {
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

/// 整批探测并按判出的编码解码：返回编码与逐项结果（与输入同序）；判不出时 None，
/// 调用方保持原样。
pub fn decode_batch(values: &[&[u8]]) -> Option<(&'static Encoding, Vec<String>)> {
    let enc = detect_bytes(values.iter().copied())?;
    let out = values
        .iter()
        .map(|b| enc.decode_without_bom_handling(b).0.into_owned())
        .collect();
    Some((enc, out))
}

// ── 整份文档（字幕 / 歌词 / 播放列表 / 纯文本）──────────────────────────────────────────

/// 整份文档里允许的「坏字符」（解码错误 + 不该出现在该编码正文里的字符）占非 ASCII 字符的
/// 上限：每 [DOCUMENT_BAD_DIVISOR] 个非 ASCII 字符容一个。
const DOCUMENT_BAD_DIVISOR: u64 = 100;

/// 整份文档至少要攒到的分值（四个汉字或两个假名）。实测样本里有一份英文字幕只含两个 GBK
/// 弯引号（4 个高位字节）：这点字节按哪种编码读都说得通，判不出比判错好。
const DOCUMENT_MIN_SCORE: u64 = 8;

/// 排名时每个坏字符抵掉的分值（一个汉字 2 分、日文编码里的假名 4 分）。
const DOCUMENT_BAD_PENALTY: u64 = 8;

/// 一个候选编码解整份文档的统计。
struct DocumentAssessment {
    /// [score_char] 的分值合计。
    score: u64,
    /// 解出的非 ASCII 字符数（含坏字符）。
    non_ascii: u64,
    /// 解码错误（U+FFFD）与 [score_char] 淘汰的字符数。
    bad: u64,
    /// 孤立的非 ASCII 字符数：前后都是 ASCII（或文档首尾），且至少一侧是 ASCII 字母。
    /// 只算「贴着字母」的：卡拉 OK 字幕 / 逐字歌词里每个字都被 `{\k20}`、`<00:12.34>` 隔开，
    /// 两侧是括号而不是字母，不能算进来。
    isolated: u64,
    /// 半角片假名（U+FF61..U+FF9F）字符数。
    halfwidth_kana: u64,
}

impl DocumentAssessment {
    fn of(enc: &'static Encoding, text: &str) -> Self {
        let mut a = DocumentAssessment {
            score: 0,
            non_ascii: 0,
            bad: 0,
            isolated: 0,
            halfwidth_kana: 0,
        };
        // 文档开头之前当作 ASCII 非字母。
        let mut prev: char = '\n';
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            let before = prev;
            prev = c;
            if c.is_ascii() {
                // 控制符（NUL、ESC…）说明这不是文本；换行 / 制表符不算。
                if score_char(enc, c).is_none() {
                    a.bad += 1;
                }
                continue;
            }
            a.non_ascii += 1;
            let after: char = chars.peek().copied().unwrap_or('\n');
            if before.is_ascii()
                && after.is_ascii()
                && (before.is_ascii_alphabetic() || after.is_ascii_alphabetic())
            {
                a.isolated += 1;
            }
            if ('\u{FF61}'..='\u{FF9F}').contains(&c) {
                a.halfwidth_kana += 1;
            }
            match score_char(enc, c) {
                Some(s) => a.score += u64::from(s),
                None => a.bad += 1,
            }
        }
        a
    }

    /// 结构证据（见模块文档）：解出的非 ASCII 字符多数孤立地贴着 ASCII 字母，或半数以上是
    /// 半角片假名，都说明原文是单字节西文编码而不是这个候选。
    fn shaped_like_cjk(&self) -> bool {
        self.isolated * 2 <= self.non_ascii && self.halfwidth_kana * 2 <= self.non_ascii
    }

    fn acceptable(&self) -> bool {
        self.score >= DOCUMENT_MIN_SCORE
            && self.bad * DOCUMENT_BAD_DIVISOR <= self.non_ascii
            && self.shaped_like_cjk()
    }

    fn rank(&self) -> u64 {
        self.score.saturating_sub(self.bad * DOCUMENT_BAD_PENALTY)
    }
}

/// 这份字节是不是「基本上是 UTF-8、只坏了少数几处」（截断的多字节序列、混进的零星坏字节）。
///
/// 本地编码的正文按 UTF-8 读几乎处处非法：合法的多字节序列远少于非法序列。反过来，坏了
/// 几处的 UTF-8 文档按 GBK 读却几乎零错误（GBK 的首尾字节范围几乎覆盖全部高位字节），
/// 不先挡掉就会被整份解成乱码。
pub fn mostly_utf8(bytes: &[u8]) -> bool {
    let mut valid = 0usize;
    let mut invalid = 0usize;
    for chunk in bytes.utf8_chunks() {
        valid += chunk.valid().chars().filter(|c| !c.is_ascii()).count();
        if !chunk.invalid().is_empty() {
            invalid += 1;
        }
    }
    valid > invalid
}

/// 整份文档（一个字幕 / 歌词 / 播放列表 / 纯文本文件的全部字节）判本地编码并解码。
///
/// 与 [detect_bytes] 的差别只在容错口径：短字符串（ID3 帧、zip 条目名）要求候选零错误、
/// 零表外字符；整份文件几十 KB，一处截断、一个坏字节、一个没列进 [score_char] 的符号都会让
/// 正确的编码被淘汰。这里每 [DOCUMENT_BAD_DIVISOR] 个非 ASCII 字符容一个坏字符，坏处解成
/// U+FFFD；排名按分值减坏字符罚分，同分仍按 [CANDIDATES] 的顺序。
///
/// 返回 None（调用方保持原有处理）：全 ASCII、[mostly_utf8]、像真 Latin-1 文本、或没有候选
/// 落在容错口径内、攒够 [DOCUMENT_MIN_SCORE] 并通过结构证据
/// （[DocumentAssessment::shaped_like_cjk]）。
///
/// 开头的 UTF-8 BOM（EF BB BF）先剥掉再判：现实里有「带 UTF-8 BOM、正文却是本地编码」的坏
/// 文件，BOM 三字节不是正文。
///
/// 已知判不对的输入（字节层面与候选同形，本模块没有词频模型）：EUC-KR 韩文等其它双字节
/// 编码，会被 GBK / Big5 零错误解成汉字。
pub fn decode_document(bytes: &[u8]) -> Option<(&'static Encoding, String)> {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if bytes.is_ascii() || mostly_utf8(bytes) || latin1_plausible(bytes) {
        return None;
    }
    let mut best: Option<(&'static Encoding, u64, String)> = None;
    for enc in CANDIDATES {
        let text = enc.decode_without_bom_handling(bytes).0;
        let assessment = DocumentAssessment::of(enc, &text);
        if !assessment.acceptable() {
            continue;
        }
        let rank = assessment.rank();
        if best.as_ref().is_none_or(|(_, r, _)| rank > *r) {
            best = Some((enc, rank, text.into_owned()));
        }
    }
    best.map(|(enc, _, text)| (enc, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zip_names_shift_jis_with_5c_and_7c_trail_bytes() {
        // 「表」= 95 5C、「ソ」= 83 5C、「ポ」= 83 7C：尾字节分别撞上 `\` 与 `|`。
        let names: Vec<Vec<u8>> = ["表紙/ソード01.jpg", "表紙/ポスター02.jpg", "readme.txt"]
            .iter()
            .map(|s| SHIFT_JIS.encode(s).0.into_owned())
            .collect();
        assert!(names[0].contains(&0x5C) && names[1].contains(&0x7C));
        let refs: Vec<&[u8]> = names.iter().map(Vec::as_slice).collect();
        let (enc, out) = decode_batch(&refs).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(
            out,
            vec!["表紙/ソード01.jpg", "表紙/ポスター02.jpg", "readme.txt"]
        );
    }

    #[test]
    fn zip_names_gbk_are_recovered() {
        let names: Vec<Vec<u8>> = ["第一话/页面01.png", "第一话/页面02.png"]
            .iter()
            .map(|s| GBK.encode(s).0.into_owned())
            .collect();
        let refs: Vec<&[u8]> = names.iter().map(Vec::as_slice).collect();
        let (enc, out) = decode_batch(&refs).expect("detected");
        assert_eq!(enc, GBK);
        assert_eq!(out, vec!["第一话/页面01.png", "第一话/页面02.png"]);
    }

    #[test]
    fn zip_names_ascii_or_undecodable_are_not_detected() {
        assert!(decode_batch(&[b"001.jpg".as_slice(), b"002.jpg".as_slice()]).is_none());
        assert!(decode_batch(&[[b'a', 0xFF, 0xFF, 0xFF].as_slice()]).is_none());
        assert!(decode_batch(&[]).is_none());
    }

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
    fn gbk_tag_with_middle_dot_is_recovered() {
        let (enc, out) = repair(&[encoded(GBK, "周杰伦·晴天"), encoded(GBK, "叶惠美")]);
        assert_eq!(enc, Some("GBK"));
        assert_eq!(out, vec!["周杰伦·晴天", "叶惠美"]);
    }

    /// 一份 ASS 字幕：ASCII 头 + [lines] 重复 [repeat] 遍的对白。
    fn ass_document(lines: &[&str], repeat: usize) -> String {
        let mut doc = String::from(
            "[Script Info]\r\nScriptType: v4.00+\r\n\r\n[Events]\r\n\
             Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n",
        );
        for k in 0..repeat {
            for (i, line) in lines.iter().enumerate() {
                doc.push_str(&format!(
                    "Dialogue: 0,0:{:02}:{:02}.00,0:{:02}:{:02}.50,Default,,0,0,0,,{line}\r\n",
                    k % 60,
                    i % 60,
                    k % 60,
                    i % 60,
                ));
            }
        }
        doc
    }

    const JA_LINES: [&str; 6] = [
        "おはよう、今日はいい天気ですね。",
        "{\\an8}♪～ 夜空に星が瞬いている ～♪",
        "えっ…本当に？　信じられないよ！",
        "ｱﾘｶﾞﾄｳ、助かった。",
        "「約束だよ」――彼女はそう言って笑った。",
        "第１２話　表示能力のテスト①",
    ];

    const ZH_HANS_LINES: [&str; 5] = [
        "早上好，今天天气真不错。",
        "{\\an8}～ 夜空中的星星在闪烁 ～",
        "诶……真的吗？简直不敢相信！",
        "“约好了哦”——她这样说着笑了。",
        "乔治·华盛顿与托马斯·杰斐逊",
    ];

    const ZH_HANT_LINES: [&str; 5] = [
        "早安，今天天氣真不錯。",
        "{\\an8}夜空中的星星在閃爍",
        "欸……真的嗎？簡直不敢相信！",
        "「約好了喔」——她這樣說著笑了。",
        "喬治·華盛頓與湯瑪斯·傑佛遜",
    ];

    fn encode_document(enc: &'static Encoding, doc: &str) -> Vec<u8> {
        let (bytes, _, had_errors) = enc.encode(doc);
        assert!(!had_errors, "document not encodable in {}", enc.name());
        bytes.into_owned()
    }

    #[test]
    fn document_in_each_legacy_encoding_is_decoded() {
        for (enc, lines) in [
            (SHIFT_JIS, &JA_LINES[..]),
            (EUC_JP, &JA_LINES[..]),
            (GBK, &ZH_HANS_LINES[..]),
            (BIG5, &ZH_HANT_LINES[..]),
        ] {
            let doc = ass_document(lines, 8);
            let bytes = encode_document(enc, &doc);
            assert!(std::str::from_utf8(&bytes).is_err());
            let (got, text) = decode_document(&bytes).expect("detected");
            assert_eq!(got, enc, "{} misdetected as {}", enc.name(), got.name());
            assert_eq!(text, doc);
        }
    }

    #[test]
    fn document_with_a_stray_bad_byte_or_truncated_tail_is_still_decoded() {
        let doc = ass_document(&JA_LINES, 8);
        let clean = encode_document(SHIFT_JIS, &doc);

        // 行尾（CRLF 之前）插一个不属于任何候选编码的字节。
        let at = clean.len() / 2;
        let at = at + clean[at..].iter().position(|&b| b == b'\r').unwrap();
        let mut junk = clean.clone();
        junk.insert(at, 0xFF);
        // 短字符串口径（零错误）下这份输入判不出来。
        assert!(detect_bytes([junk.as_slice()]).is_none());
        let (enc, text) = decode_document(&junk).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(text.matches('\u{FFFD}').count(), 1);
        assert_eq!(text.replace('\u{FFFD}', ""), doc);

        // 文件在一个双字节字符中间截断。
        // 「は」= 82 CD：留下首字节 82。
        let cut = clean.windows(2).rposition(|w| w == [0x82, 0xCD]).unwrap();
        let truncated = &clean[..=cut];
        assert!(detect_bytes([truncated]).is_none());
        let (enc, text) = decode_document(truncated).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert!(text.ends_with('\u{FFFD}'));
        assert!(doc.starts_with(text.trim_end_matches('\u{FFFD}')));
    }

    #[test]
    fn short_input_keeps_the_zero_error_rule() {
        // 非 ASCII 字符不足 [DOCUMENT_BAD_DIVISOR] 个时一个坏字符都不容。
        let mut bytes = encode_document(SHIFT_JIS, "夜に駆ける");
        bytes.push(0xFF);
        assert!(decode_document(&bytes).is_none());
        assert!(decode_document(&[b'a', 0xFF, 0xFF, 0xFF]).is_none());
        let (enc, text) = decode_document(&encode_document(SHIFT_JIS, "夜に駆ける")).unwrap();
        assert_eq!((enc, text.as_str()), (SHIFT_JIS, "夜に駆ける"));
        // 实测样本的形态：英文字幕里只有两个 GBK 弯引号（A1 AF）。证据不足，不猜。
        let quotes = b"Let\xA1\xAFs capture ingredients!\r\nLet\xA1\xAFs eat!\r\n";
        assert!(decode_document(quotes).is_none());
    }

    #[test]
    fn damaged_utf8_document_is_not_reinterpreted() {
        for lines in [&JA_LINES[..], &ZH_HANS_LINES[..], &ZH_HANT_LINES[..]] {
            let doc = ass_document(lines, 8);
            let utf8 = doc.as_bytes();
            let at = utf8.iter().position(|&b| b >= 0x80).unwrap();

            // 掉了一个字节（多字节序列被截断）。
            let mut cut = utf8.to_vec();
            cut.remove(at);
            assert!(std::str::from_utf8(&cut).is_err());
            assert!(mostly_utf8(&cut));
            assert!(decode_document(&cut).is_none());

            // 混进一个坏字节。
            let mut junk = utf8.to_vec();
            junk.insert(at, 0xFF);
            assert!(decode_document(&junk).is_none());
        }
        // 反例：本地编码的正文不会被当成「基本是 UTF-8」。
        for (enc, lines) in [
            (SHIFT_JIS, &JA_LINES[..]),
            (EUC_JP, &JA_LINES[..]),
            (GBK, &ZH_HANS_LINES[..]),
            (BIG5, &ZH_HANT_LINES[..]),
        ] {
            assert!(!mostly_utf8(&encode_document(enc, &ass_document(lines, 8))));
        }
    }

    #[test]
    fn ascii_and_latin1_documents_are_left_alone() {
        assert!(decode_document(b"").is_none());
        assert!(decode_document(ass_document(&["Hello, world."], 4).as_bytes()).is_none());
        // Windows-1252 的法语 / 德语字幕：高位字节零散出现，不是双字节编码。
        let doc = ass_document(&["Déjà vu, ça va très bien.", "Größe für Élise"], 8);
        let latin1: Vec<u8> = doc.chars().map(|c| c as u32 as u8).collect();
        assert!(decode_document(&latin1).is_none());
    }

    /// 一份 SRT：[lines] 重复 [repeat] 遍。
    fn srt_document(lines: &[&str], repeat: usize) -> String {
        let mut doc = String::new();
        let mut n = 0usize;
        for _ in 0..repeat {
            for line in lines {
                n += 1;
                doc.push_str(&format!(
                    "{n}\r\n00:{:02}:{:02},000 --> 00:{:02}:{:02},500\r\n{line}\r\n\r\n",
                    n / 60 % 60,
                    n % 60,
                    n / 60 % 60,
                    n % 60,
                ));
            }
        }
        doc
    }

    fn encode_single_byte(enc: &'static Encoding, doc: &str) -> Vec<u8> {
        let bytes = encode_document(enc, doc);
        assert!(bytes.iter().any(|&b| b >= 0x80));
        assert!(std::str::from_utf8(&bytes).is_err());
        bytes
    }

    /// 只看分值与容错口径（不看结构证据）时会接受这份字节的候选 —— 用来证明下面的用例
    /// 确实是靠结构证据挡住的。
    fn passes_without_shape(bytes: &[u8]) -> Vec<&'static str> {
        CANDIDATES
            .iter()
            .filter(|&&enc| {
                let text = enc.decode_without_bom_handling(bytes).0;
                let a = DocumentAssessment::of(enc, &text);
                a.score >= DOCUMENT_MIN_SCORE && a.bad * DOCUMENT_BAD_DIVISOR <= a.non_ascii
            })
            .map(|enc| enc.name())
            .collect()
    }

    /// [lines] 重复 20 遍的 SRT，末尾再接一条只出现一次的 [tail] cue。
    fn srt_with_tail(lines: &[&str], tail: &str) -> String {
        let mut doc = srt_document(lines, 20);
        doc.push_str(&format!(
            "999\r\n00:59:00,000 --> 00:59:01,500\r\n{tail}\r\n\r\n"
        ));
        doc
    }

    #[test]
    fn western_single_byte_documents_are_not_decoded_as_cjk() {
        use encoding_rs::{WINDOWS_874, WINDOWS_1252, WINDOWS_1256};
        const EN: [&str; 5] = [
            "I don’t know what you’re talking about.",
            "It’s fine, we’ll manage.",
            "She’s gone, isn’t she?",
            "They’ve left already.",
            "I’m sure he’d agree.",
        ];
        // 1) 弯撇号 + 一行 `“Wait…”`（85 94 相邻 → latin1_plausible 整份判否）。从前判成
        //    Shift_JIS：`I don稚 know what you池e talking about.`。
        let en_ellipsis = encode_single_byte(WINDOWS_1252, &srt_with_tail(&EN, "“Wait…”"));
        assert!(!latin1_plausible(&en_ellipsis));
        assert_eq!(passes_without_shape(&en_ellipsis), ["Shift_JIS", "GBK"]);
        assert!(decode_document(&en_ellipsis).is_none());

        // 2) 破折号紧跟左引号（97 93 相邻）。
        let en_dash = encode_single_byte(WINDOWS_1252, &srt_with_tail(&EN, "He said—“No.”"));
        assert!(!latin1_plausible(&en_dash));
        assert!(!passes_without_shape(&en_dash).is_empty());
        assert!(decode_document(&en_dash).is_none());

        // 3) 没有 ß 的瑞士德语 + 一处 `„Ü`（84 DC 相邻）。从前判成 GBK：
        //    `Ich m鯿hte f黵 dich k鋗pfen.`。
        let de = [
            "Ich möchte für dich kämpfen.",
            "Das wäre schön, natürlich.",
            "Wir müssen früher gehen.",
            "Hörst du die Vögel?",
            "Grüezi, schönen Abend.",
        ];
        let de = encode_single_byte(WINDOWS_1252, &srt_with_tail(&de, "„Überraschung"));
        assert!(!latin1_plausible(&de));
        assert!(passes_without_shape(&de).contains(&"GBK"));
        assert!(decode_document(&de).is_none());

        // 4) 阿拉伯文 Windows-1256：字节成串，大半落在 Shift_JIS 的单字节半角片假名区。
        let ar = ["مرحبا، كيف حالك؟", "لا أعرف ماذا تقصد."];
        let ar = encode_single_byte(WINDOWS_1256, &srt_document(&ar, 20));
        assert!(passes_without_shape(&ar).contains(&"Shift_JIS"));
        assert!(decode_document(&ar).is_none());

        // 5) 泰文 TIS-620 / Windows-874：同样几乎全在半角片假名区。
        let th = ["สวัสดีครับ", "ขอบคุณมากครับ", "ผมรักคุณ"];
        let th = encode_single_byte(WINDOWS_874, &srt_document(&th, 20));
        assert!(passes_without_shape(&th).contains(&"Shift_JIS"));
        assert!(decode_document(&th).is_none());
    }

    #[test]
    fn halfwidth_kana_majority_is_rejected_but_minority_is_kept() {
        // 只有半角片假名的字节串（阿拉伯文 / 泰文被 Shift_JIS 解开后的形态）不认。
        let only_halfwidth = encode_document(SHIFT_JIS, &srt_document(&["ｱﾘｶﾞﾄｳ ｺﾞｻﾞｲﾏｽ"], 10));
        assert_eq!(passes_without_shape(&only_halfwidth), vec!["Shift_JIS"]);
        assert!(decode_document(&only_halfwidth).is_none());
        // 真日文字幕里夹着半角片假名的行照常判。
        let doc = srt_document(&JA_LINES, 4);
        let (enc, text) = decode_document(&encode_document(SHIFT_JIS, &doc)).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(text, doc);
    }

    #[test]
    fn cjk_isolated_between_markup_is_still_decoded() {
        // 卡拉 OK：每个字都被 `{\k..}` 隔开 —— 两侧是括号，不是字母。
        let karaoke = [
            "{\\k20}夜{\\k15}に{\\k30}駆{\\k10}け{\\k25}る",
            "{\\k20}沈{\\k15}む{\\k30}よ{\\k10}う{\\k25}に",
            "{\\k20}溶{\\k15}け{\\k30}て{\\k10}ゆ{\\k25}く",
        ];
        let doc = ass_document(&karaoke, 8);
        let (enc, text) = decode_document(&encode_document(SHIFT_JIS, &doc)).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(text, doc);
        // 逐字歌词（LRC 增强格式）。
        let lrc = "[00:12.00]<00:12.00>晴<00:12.40>天<00:12.80>的<00:13.20>风\r\n".repeat(6);
        let (enc, text) = decode_document(&encode_document(GBK, &lrc)).expect("detected");
        assert_eq!(enc, GBK);
        assert_eq!(text, lrc);
        // 中英混排：少数汉字贴着字母（T恤、A型）不影响整体。
        let mixed = srt_document(
            &["他穿着T恤走进了KTV。", "我是A型血，你呢？", "明天见。"],
            6,
        );
        let (enc, text) = decode_document(&encode_document(GBK, &mixed)).expect("detected");
        assert_eq!(enc, GBK);
        assert_eq!(text, mixed);
    }

    #[test]
    fn utf8_bom_before_legacy_body_is_stripped() {
        const BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];
        // 长文档：BOM 不再被解成 `\u{FFFD}ｿ` 混进首行。
        let doc = srt_document(&JA_LINES, 10);
        let mut bytes = BOM.to_vec();
        bytes.extend_from_slice(&encode_document(SHIFT_JIS, &doc));
        let (enc, text) = decode_document(&bytes).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(text, doc);
        assert!(text.starts_with("1\r\n"));
        // 短文档（非 ASCII 字符不足 [DOCUMENT_BAD_DIVISOR] 个）：从前 BOM 解出的那个坏字符
        // 超出零容错，整份判不出。
        let doc = srt_document(&JA_LINES[..3], 1);
        let mut bytes = BOM.to_vec();
        bytes.extend_from_slice(&encode_document(SHIFT_JIS, &doc));
        let (enc, text) = decode_document(&bytes).expect("detected");
        assert_eq!(enc, SHIFT_JIS);
        assert_eq!(text, doc);
        // 只有 BOM / BOM + ASCII：不动。
        assert!(decode_document(&BOM).is_none());
        assert!(decode_document(b"\xEF\xBB\xBFhello").is_none());
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

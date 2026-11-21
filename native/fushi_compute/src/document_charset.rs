//! 整份文本文件（字幕 / 歌词 / 播放列表 / 纯文本）判编码：[crate::legacy_text] 的中日编码
//! 计分 + `chardetng`（Firefox 的旧网页编码探测器，带各编码的字频 / 字对模型）。
//!
//! 为什么两层：[crate::legacy_text::decode_document] 只认 Shift_JIS / GBK / EUC-JP / Big5，
//! 判据是字节形状与字符类别，没有词频模型。字节层面与候选同形的编码它判不对 ——
//! EUC-KR（CP949）的韩文字节全落在 GB2312 区，GBK / Big5 零错误解成一串汉字；
//! Windows-1251 保加利亚文 / 俄文偶尔也被解成汉字；单字节西文编码（Windows-1252 / 1256 /
//! 874…）被它判否后只能降级成宽松 UTF-8，重音字母、弯撇号处处变 U+FFFD。`chardetng`
//! 覆盖全部 WHATWG 旧编码，能把这些分开。
//!
//! 分工（中日编码的判据是用真实字幕样本调过的，见 legacy_text 模块文档，不交给 chardetng）：
//!
//! 1. 全 ASCII、[crate::legacy_text::mostly_utf8]（基本是 UTF-8、只坏了几处）→ None。
//! 2. chardetng 的结论**不是**四个中日候选之一（EUC-KR、单字节编码）且按它解码通过
//!    [plausible] → 采用 chardetng，盖过 legacy_text 的结论（那正是 legacy_text 的盲区）。
//! 3. 否则交给 [crate::legacy_text::decode_document]（chardetng 也说是中日编码、或它的结论
//!    解出来不像正文时）。legacy_text 判不出时返回 None —— chardetng 判成中日编码而
//!    legacy_text 不认，多半是证据太少（一份英文字幕里两个 GBK 弯引号），判不出比判错好。
//!
//! legacy_text.rs 还被 native/fushi_music 以 `#[path]` 编入（ID3 修复），所以 chardetng 只在
//! 本文件引用，不进那份共用源码。

use crate::legacy_text;
use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use encoding_rs::{BIG5, EUC_JP, EUC_KR, Encoding, GBK, SHIFT_JIS};

/// 交给 [legacy_text::decode_document] 判的中日编码（与它的候选同一组）。
const CJK_CANDIDATES: [&Encoding; 4] = [SHIFT_JIS, GBK, EUC_JP, BIG5];

/// 采用 chardetng 的结论时允许的坏字符占比：每 [BAD_DIVISOR] 个非 ASCII 字符容一个
/// （与 legacy_text 的整份文档口径一致）。
const BAD_DIVISOR: usize = 100;

/// 采用 chardetng 的结论至少要有的高位字节数（与 legacy_text「至少四个汉字」同一口径）：
/// 几个孤零零的高位字节按哪种单字节编码读都是几个字母（CP932 的「日本語」六个字节按
/// Windows-1252 读是 `“ú–{Œê`），判不出比判错好。
const MIN_HIGH_BYTES: usize = 8;

/// 不该出现在正文里的字符：解码错误、C0 控制符（换行 / 制表 / 换页除外）、C1 控制符。
/// Windows-1252 把 0x81 / 0x8D / 0x8F / 0x90 / 0x9D 映成 C1 控制符，解出它们说明不是这种编码。
fn is_bad(c: char) -> bool {
    match c {
        '\u{FFFD}' => true,
        '\t' | '\n' | '\r' | '\u{0C}' => false,
        _ => c.is_control(),
    }
}

/// 按 chardetng 判出的 [enc] 解出的 [text] 像不像正文：坏字符不超过口径；EUC-KR 另要求解出的
/// 非 ASCII 字符过半是谚文音节 —— 韩文正文以谚文为主，中文 / 日文字节按 CP949 读出来是汉字、
/// 符号与 CP949 扩展区谚文混杂的一片。
fn plausible(enc: &'static Encoding, text: &str) -> bool {
    let mut non_ascii = 0usize;
    let mut bad = 0usize;
    let mut hangul = 0usize;
    for c in text.chars() {
        if is_bad(c) {
            bad += 1;
        }
        if c.is_ascii() {
            continue;
        }
        non_ascii += 1;
        if ('\u{AC00}'..='\u{D7A3}').contains(&c) {
            hangul += 1;
        }
    }
    if non_ascii == 0 || bad * BAD_DIVISOR > non_ascii {
        return false;
    }
    enc != EUC_KR || hangul * 2 > non_ascii
}

/// 整份文档判编码并解码；判不出时 None（调用方保持原有处理）。开头的 UTF-8 BOM 不算正文
/// （现实里有「UTF-8 BOM + 本地编码正文」的坏文件）。判据见模块文档。
pub fn decode_document(bytes: &[u8]) -> Option<(&'static Encoding, String)> {
    let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if body.is_ascii() || legacy_text::mostly_utf8(body) {
        return None;
    }
    // ISO-2022-JP 是纯 7 位字节，上面全 ASCII 就返回了，这里不会遇到。
    let mut detector = EncodingDetector::new(Iso2022JpDetection::Deny);
    detector.feed(body, true);
    // tld = None 等同 `.com`：不偏向任何地区。UTF-8 已由 mostly_utf8 处理，这里不许猜 UTF-8。
    let guess = detector.guess(None, Utf8Detection::Deny);
    let high_bytes = body.iter().filter(|&&b| b >= 0x80).count();
    if !CJK_CANDIDATES.contains(&guess) && high_bytes >= MIN_HIGH_BYTES {
        let text = guess.decode_without_bom_handling(body).0;
        if plausible(guess, &text) {
            return Some((guess, text.into_owned()));
        }
    }
    legacy_text::decode_document(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use encoding_rs::{WINDOWS_874, WINDOWS_1251, WINDOWS_1252, WINDOWS_1256};

    fn srt_document(lines: &[&str], repeat: usize) -> String {
        let mut doc = String::new();
        let mut n = 0usize;
        for _ in 0..repeat {
            for line in lines {
                n += 1;
                doc.push_str(&format!(
                    "{n}\r\n00:{:02}:{:02},000 --> 00:{:02}:{:02},500\r\n{line}\r\n\r\n",
                    n / 60,
                    n % 60,
                    n / 60,
                    n % 60
                ));
            }
        }
        doc
    }

    fn encode(enc: &'static Encoding, doc: &str) -> Vec<u8> {
        let (bytes, _, had_errors) = enc.encode(doc);
        assert!(!had_errors, "document not encodable in {}", enc.name());
        bytes.into_owned()
    }

    /// encoding_rs 的 encode 只出 UTF-8 / 多字节旧编码；单字节编码逐字符查表反编出来。
    fn encode_single_byte(enc: &'static Encoding, doc: &str) -> Vec<u8> {
        let table: Vec<(char, u8)> = (0x80u8..=0xFF)
            .filter_map(|b| {
                let byte = [b];
                let (s, had_errors) = enc.decode_without_bom_handling(&byte);
                (!had_errors).then(|| (s.chars().next().unwrap(), b))
            })
            .collect();
        doc.chars()
            .map(|c| {
                if c.is_ascii() {
                    c as u8
                } else {
                    table
                        .iter()
                        .find(|(t, _)| *t == c)
                        .unwrap_or_else(|| panic!("{c} not in {}", enc.name()))
                        .1
                }
            })
            .collect()
    }

    const KO_LINES: [&str; 6] = [
        "안녕하세요, 오늘은 날씨가 정말 좋네요.",
        "♪ 밤하늘에 별이 반짝이고 있어 ♪",
        "어… 정말이야? 믿을 수가 없어!",
        "「약속이야」 그녀는 그렇게 말하며 웃었다.",
        "제12화 표시 능력 테스트",
        "내일은 비가 올지도 몰라.",
    ];

    const JA_LINES: [&str; 6] = [
        "おはよう、今日はいい天気ですね。",
        "{\\an8}♪～ 夜空に星が瞬いている ～♪",
        "えっ…本当に？　信じられないよ！",
        "ｱﾘｶﾞﾄｳ、助かった。",
        "「約束だよ」――彼女はそう言って笑った。",
        "第１２話　表示能力のテスト①",
    ];

    const JA_EUC_LINES: [&str; 4] = [
        "おはよう、今日はいい天気ですね。",
        "えっ…本当に？　信じられないよ！",
        "「約束だよ」彼女はそう言って笑った。",
        "ソフトウェアの予定表を確認します。",
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

    #[test]
    fn euc_kr_korean_is_not_decoded_as_hanzi() {
        for repeat in [1, 4, 20] {
            let doc = srt_document(&KO_LINES, repeat);
            let bytes = encode(EUC_KR, &doc);
            // 修前：legacy_text 把它零错误解成 GBK / Big5 汉字。
            assert!(legacy_text::decode_document(&bytes).is_some());
            let (enc, text) = decode_document(&bytes).expect("detected");
            assert_eq!(enc, EUC_KR, "repeat {repeat}: got {}", enc.name());
            assert_eq!(text, doc);
        }
    }

    #[test]
    fn cjk_documents_still_go_to_legacy_text() {
        for (enc, lines) in [
            (SHIFT_JIS, &JA_LINES[..]),
            (EUC_JP, &JA_EUC_LINES[..]),
            (GBK, &ZH_HANS_LINES[..]),
            (BIG5, &ZH_HANT_LINES[..]),
        ] {
            for repeat in [1, 3, 20] {
                let doc = srt_document(lines, repeat);
                let bytes = encode(enc, &doc);
                let (got, text) = decode_document(&bytes).expect("detected");
                assert_eq!(
                    got,
                    enc,
                    "{} x{repeat} misdetected as {}",
                    enc.name(),
                    got.name()
                );
                assert_eq!(text, doc);
            }
        }
        // 短到只有一个标题也照旧。
        let (enc, text) = decode_document(&encode(SHIFT_JIS, "夜に駆ける")).unwrap();
        assert_eq!((enc, text.as_str()), (SHIFT_JIS, "夜に駆ける"));
    }

    #[test]
    fn single_byte_documents_are_decoded_instead_of_lossy_utf8() {
        let en = [
            "I don’t know what you’re talking about.",
            "It’s fine, we’ll manage.",
            "She’s gone, isn’t she?",
            "They’ve left already.",
            "I’m sure he’d agree.",
            "“Wait…”",
        ];
        let de = [
            "Ich möchte für dich kämpfen.",
            "Das wäre schön, natürlich.",
            "Wir müssen früher gehen.",
            "Hörst du die Vögel?",
            "„Überraschung“, sagte er.",
        ];
        let fr = [
            "Où est la bibliothèque ?",
            "C’est déjà l’été, ça va très bien.",
        ];
        // 太短、太单调的保加利亚文 chardetng 会判成 Windows-1255，用接近真实对白的句子。
        let bg = [
            "Здравей, как си днес? Не знам какво искаш да кажеш.",
            "Утре може да вали дъжд.",
            "Той каза, че ще дойде вечерта, но още го няма.",
            "Трябва да тръгваме веднага, иначе ще закъснеем за влака.",
            "Благодаря ти за всичко, което направи за мен.",
        ];
        let ru = ["Привет, как дела?", "Я не знаю, что ты имеешь в виду."];
        let ar = ["مرحبا، كيف حالك؟", "لا أعرف ماذا تقصد."];
        let th = ["สวัสดีครับ", "ขอบคุณมากครับ", "ผมรักคุณ"];
        for (enc, lines) in [
            (WINDOWS_1252, &en[..]),
            (WINDOWS_1252, &de[..]),
            (WINDOWS_1252, &fr[..]),
            (WINDOWS_1251, &bg[..]),
            (WINDOWS_1251, &ru[..]),
            (WINDOWS_1256, &ar[..]),
            (WINDOWS_874, &th[..]),
        ] {
            let doc = srt_document(lines, 20);
            let bytes = encode_single_byte(enc, &doc);
            let (got, text) = decode_document(&bytes).expect("detected");
            assert_eq!(got, enc, "{:?} misdetected as {}", lines[0], got.name());
            assert_eq!(text, doc);
        }
    }

    #[test]
    fn utf8_ascii_and_garbage_are_left_to_the_caller() {
        assert!(decode_document(b"").is_none());
        assert!(decode_document(b"WEBVTT\n\n00:01.000 --> 00:02.000\nhi\n").is_none());
        let ko = srt_document(&KO_LINES, 4);
        assert!(decode_document(ko.as_bytes()).is_none());
        // 坏了一处的 UTF-8 不重解。
        let mut damaged = ko.into_bytes();
        let cut = damaged.iter().position(|&b| b >= 0x80).unwrap();
        damaged.remove(cut);
        assert!(decode_document(&damaged).is_none());
        // 几个孤零零的高位字节：chardetng 会猜 IBM866（`БББ`）、Windows-1252，证据太少不采用。
        assert!(decode_document(b"Dialogue: \x81\x81\x81\n").is_none());
        assert!(decode_document(b"Dialogue: \x93\xFA\x96\x7B\x8C\xEA\n").is_none());
    }

    #[test]
    fn utf8_bom_before_legacy_body_is_not_part_of_the_text() {
        let doc = srt_document(&KO_LINES, 4);
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend(encode(EUC_KR, &doc));
        assert_eq!(decode_document(&bytes), Some((EUC_KR, doc)));
    }
}

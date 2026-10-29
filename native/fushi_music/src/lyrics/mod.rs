//! 歌词胖核心（设计 §5）：全格式解析 → 统一时间轴 [model::Timeline] → 紧凑二进制（[wire]），
//! 整首一次跨 FFI（[ffi]）。逐帧擦色在 Flutter 本地插值，不回 Rust。
//!
//! | 类别 | 格式 | 模块 |
//! |---|---|---|
//! | 行级 | LRC、SRT、WebVTT、SAMI、纯文本 | [lrc]、[subtitle] |
//! | 字级 | 增强 LRC（A2）、ESLyric 逐字 LRC、WebVTT cue 内时间戳 | [lrc]、[subtitle] |
//! | 音节级 | TTML（AMLL / Apple 方言）、Lyricify Syllable | [ttml]、[syllabic] |
//! | 卡拉 OK 字幕 | ASS / SSA `\k` `\K` `\kf` `\ko` `\kt`（只结构化） | [ass] |
//! | 平台格式 | KRC（解密）、QRC 明文 / XML 包装、YRC | [syllabic] |
//! | 卡拉 OK 歌曲 | UltraStar `.txt`、MIDI / `.kar` | [ultrastar]、[midi] |
//! | 内嵌 | ID3 USLT / SYLT、Vorbis LYRICS / UNSYNCEDLYRICS、MP4 ©lyr | [embedded] |
//!
//! 已知不支持：QQ 音乐加密 QRC（本地缓存的二进制 `.qrc`，需 QQ 定制 3DES，没有可验证的公开
//! 向量）→ 明确报错而不是出乱码。

pub mod ass;
pub mod embedded;
pub mod export;
pub mod ffi;
pub mod json;
pub mod lrc;
pub mod markup;
pub mod merge;
pub mod midi;
pub mod model;
pub mod subtitle;
pub mod syllabic;
pub mod text;
pub mod time;
pub mod ttml;
pub mod ultrastar;
pub mod wire;

use model::*;

/// 解析器版本：任何会改变解析结果的修改都要升它；`music_lyrics.timeline_version` 与它不符
/// 的缓存在读取时重建。
/// 2：ASS 特效检测加了 `\org`、`\p1` 绘图与逐字定位（P3）。
/// 3：翻译合并改为估计整体偏移 + 单调对齐，对不上的翻译挂靠原文行、不再成独立行。
pub const PARSER_VERSION: u32 = 3;

/// 按格式提示（扩展名或格式名，大小写不敏感，可空）+ 内容嗅探解析。`duration_ms` 是曲长
/// （补最后一行终点），未知传 None。
pub fn parse(bytes: &[u8], hint: &str, duration_ms: Option<i64>) -> Result<Timeline, String> {
    let hint = hint.trim().trim_start_matches('.').to_ascii_lowercase();
    if midi::is_midi(bytes) {
        return midi::parse(bytes, duration_ms).ok_or_else(|| "malformed MIDI file".to_owned());
    }
    if matches!(hint.as_str(), "mid" | "midi" | "kar") {
        return Err("not a MIDI file".to_owned());
    }
    if syllabic::is_encrypted_krc(bytes) {
        let plain =
            syllabic::decrypt_krc(bytes).ok_or_else(|| "KRC decryption failed".to_owned())?;
        let text = text::normalize_newlines(&text::decode_text(&plain));
        return Ok(syllabic::parse(&text, syllabic::Flavor::Krc, duration_ms));
    }
    let text = text::normalize_newlines(&text::decode_text(bytes));
    if hint == "qrc" && !text.contains('[') && !text.contains("LyricContent") {
        return Err(
            "encrypted QRC is not supported (decrypt it with the QQ Music client first)".to_owned(),
        );
    }
    let by_hint = match hint.as_str() {
        "ttml" | "xml" if ttml::looks_like_ttml(&text) => Some(parse_ttml(&text, duration_ms)?),
        "ttml" => return Err("not a TTML document".to_owned()),
        "ass" | "ssa" => Some(ass::parse(&text, duration_ms)),
        "srt" => Some(subtitle::parse_srt(&text, duration_ms)),
        "vtt" | "webvtt" => Some(subtitle::parse_vtt(&text, duration_ms)),
        "smi" | "sami" => Some(subtitle::parse_sami(&text, duration_ms)),
        "lys" => Some(syllabic::parse(&text, syllabic::Flavor::Lys, duration_ms)),
        "qrc" => {
            let body = syllabic::unwrap_qrc_xml(&text).unwrap_or_else(|| text.clone());
            let body = text::normalize_newlines(&body);
            let flavor = syllabic::sniff(&body).unwrap_or(syllabic::Flavor::Qrc);
            Some(syllabic::parse(&body, flavor, duration_ms))
        }
        "yrc" => Some(syllabic::parse(&text, syllabic::Flavor::Yrc, duration_ms)),
        "krc" => Some(syllabic::parse(&text, syllabic::Flavor::Krc, duration_ms)),
        "lrc" => Some(lrc::parse(&text, duration_ms)),
        "ultrastar" => Some(ultrastar::parse(&text, duration_ms)),
        _ => None,
    };
    if let Some(t) = by_hint {
        return Ok(t);
    }
    sniff_parse(&text, duration_ms)
}

fn parse_ttml(text: &str, duration_ms: Option<i64>) -> Result<Timeline, String> {
    ttml::parse(text, duration_ms).ok_or_else(|| "malformed TTML document".to_owned())
}

/// 没有可靠提示（`.txt`、内嵌文本、未知扩展名）时按内容判。
fn sniff_parse(text: &str, duration_ms: Option<i64>) -> Result<Timeline, String> {
    let head = text.trim_start();
    if ttml::looks_like_ttml(head) {
        return parse_ttml(text, duration_ms);
    }
    if text.contains("LyricContent=\"") {
        if let Some(body) = syllabic::unwrap_qrc_xml(text) {
            let body = text::normalize_newlines(&body);
            let flavor = syllabic::sniff(&body).unwrap_or(syllabic::Flavor::Qrc);
            return Ok(syllabic::parse(&body, flavor, duration_ms));
        }
    }
    if ass::looks_like_ass(head) {
        return Ok(ass::parse(text, duration_ms));
    }
    if head.starts_with("WEBVTT") {
        return Ok(subtitle::parse_vtt(text, duration_ms));
    }
    if subtitle::looks_like_sami(head) {
        return Ok(subtitle::parse_sami(text, duration_ms));
    }
    if ultrastar::looks_like_ultrastar(text) {
        return Ok(ultrastar::parse(text, duration_ms));
    }
    if let Some(flavor) = syllabic::sniff(text) {
        return Ok(syllabic::parse(text, flavor, duration_ms));
    }
    if lrc::looks_like_lrc(text) {
        return Ok(lrc::parse(text, duration_ms));
    }
    if subtitle::looks_like_srt(text) {
        return Ok(subtitle::parse_srt(text, duration_ms));
    }
    Ok(plain(text))
}

/// 纯文本：每个非空行一行，没有时间（只做静态显示）。
pub fn plain(text: &str) -> Timeline {
    let mut t = Timeline::new("txt", TimingQuality::Unsynced);
    for l in text.lines() {
        let l = l.trim();
        if !l.is_empty() {
            t.lines.push(Line::whole(l, 0, 0));
        }
    }
    t.finalize(None);
    t
}

//! 歌词胖核心（设计 §5）：全格式解析 → 统一时间轴 [model::Timeline] → 紧凑二进制（[wire]），
//! 整首一次跨 FFI（[ffi]）。逐帧擦色在 Flutter 本地插值，不回 Rust。
//!
//! | 类别 | 格式 | 模块 |
//! |---|---|---|
//! | 行级 | LRC、SRT、WebVTT、SAMI、纯文本 | [lrc]、[subtitle] |
//! | 字级 | 增强 LRC（A2）、ESLyric 逐字 LRC、WebVTT cue 内时间戳 | [lrc]、[subtitle] |
//! | 音节级 | TTML（AMLL / Apple 方言）、Lyricify Syllable | [ttml]、[syllabic] |
//! | 卡拉 OK 字幕 | ASS / SSA `\k` `\K` `\kf` `\ko` `\kt`（只结构化） | [ass] |
//! | 平台格式 | KRC（解密）、QRC（明文 / XML 包装 / 加密，`[kana:]` 注音轨 → ruby）、YRC | [syllabic]、[qrc] |
//! | 卡拉 OK 歌曲 | UltraStar `.txt`、MIDI / `.kar` | [ultrastar]、[midi] |
//! | 内嵌 | ID3 USLT / SYLT、Vorbis LYRICS / UNSYNCEDLYRICS、MP4 ©lyr | [embedded] |

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
pub mod qrc;
pub mod slice;
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
/// 4：加密 QRC（本地缓存 / 接口十六进制串）解密；QRC `[kana:]` 注音轨挂成音节 ruby。
/// 5：QRC `[kana:]` 的汉字计数口径：补扩展 H / J（U+31350–3347F），`〇` `〆` 两种取舍都做完整对齐校验。
/// 6：接口十六进制密文认旧接口 XML 的 CDATA 包装（`<content><![CDATA[hex]]></content>`）。
pub const PARSER_VERSION: u32 = 6;

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
    if let Some(cipher) = qrc::sniff_encrypted(bytes, hint == "qrc") {
        let plain = qrc::decrypt(bytes, cipher)
            .ok_or_else(|| "encrypted QRC decryption failed".to_owned())?;
        let text = text::normalize_newlines(&text::decode_text(&plain));
        return Ok(parse_qrc(&text, duration_ms));
    }
    let text = text::normalize_newlines(&text::decode_text(bytes));
    let by_hint = match hint.as_str() {
        "ttml" | "xml" if ttml::looks_like_ttml(&text) => Some(parse_ttml(&text, duration_ms)?),
        "ttml" => return Err("not a TTML document".to_owned()),
        "ass" | "ssa" => Some(ass::parse(&text, duration_ms)),
        "srt" => Some(subtitle::parse_srt(&text, duration_ms)),
        "vtt" | "webvtt" => Some(subtitle::parse_vtt(&text, duration_ms)),
        "smi" | "sami" => Some(subtitle::parse_sami(&text, duration_ms)),
        "lys" => Some(syllabic::parse(&text, syllabic::Flavor::Lys, duration_ms)),
        "qrc" => Some(parse_qrc(&text, duration_ms)),
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

/// `.qrc` 明文（可能是 XML 包装）。
fn parse_qrc(text: &str, duration_ms: Option<i64>) -> Timeline {
    let body = syllabic::unwrap_qrc_xml(text).unwrap_or_else(|| text.to_owned());
    let body = text::normalize_newlines(&body);
    let flavor = syllabic::sniff(&body).unwrap_or(syllabic::Flavor::Qrc);
    syllabic::parse(&body, flavor, duration_ms)
}

/// 加密歌词（KRC / 加密 QRC）解出的明文上限。真实整首歌词（含 XML 包装、翻译、注音轨）
/// 在几十到几百 KB；zlib 压缩比可到约 1000:1，不设上限时插件结果上限（8 MiB）级别的
/// 输入就能解出 GB 级明文，OOM 是 abort、FFI 的 panic 守卫接不住。
pub const MAX_INFLATED_BYTES: usize = 4 * 1024 * 1024;

/// zlib 解压，输出超过 `limit` 字节或流损坏都返回 None（只读到 `limit + 1` 字节就停）。
pub(crate) fn inflate_bounded(data: &[u8], limit: usize) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(data)
        .take(limit as u64 + 1)
        .read_to_end(&mut out)
        .ok()?;
    (out.len() <= limit).then_some(out)
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

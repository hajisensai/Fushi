//! 单个音频文件的标签 + 音频属性（lofty）。lofty 不认的格式（TAK / TTA / DSF / DFF /
//! MKA / CAF / W64 / WMA）退化成「扩展名定编码 + 文件名作标题」，DSF 另从头部读属性。

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::{AudioFile, FileType, TaggedFileExt};
use lofty::mp4::{Mp4Codec, Mp4File};
use lofty::mpeg::MpegFile;
use lofty::picture::PictureType;
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey, Tag};

use crate::dsf;

/// 曲库认的音频扩展名（小写，不带点）。
pub const AUDIO_EXTENSIONS: &[&str] = &[
    "flac", "m4a", "alac", "mp3", "ogg", "oga", "opus", "wav", "aiff", "aif", "aifc", "ape", "wv",
    "tak", "tta", "mpc", "dsf", "dff", "aac", "mka", "caf", "w64", "wma", "mp4",
];

pub fn is_audio_extension(ext: &str) -> bool {
    AUDIO_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str())
}

/// 一个文件的标签与属性（CUE 虚拟曲目在此基础上覆盖曲目级字段）。
#[derive(Debug, Clone, Default)]
pub struct FileMeta {
    pub codec: Option<String>,
    pub is_lossless: bool,
    pub duration_ms: Option<i64>,
    pub sample_rate: Option<i64>,
    pub bit_depth: Option<i64>,
    pub channels: Option<i64>,
    pub bitrate_kbps: Option<i64>,
    pub title: Option<String>,
    pub title_sort: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_sort: Option<String>,
    pub album_artist: Option<String>,
    pub composers: Vec<String>,
    pub lyricists: Vec<String>,
    pub arrangers: Vec<String>,
    pub track_no: Option<i64>,
    pub disc_no: Option<i64>,
    pub disc_total: Option<i64>,
    pub year: Option<i64>,
    pub release_date: Option<String>,
    pub genre: Option<String>,
    pub catalog_no: Option<String>,
    pub rg_track_gain: Option<f64>,
    pub rg_track_peak: Option<f64>,
    pub rg_album_gain: Option<f64>,
    pub rg_album_peak: Option<f64>,
    pub mb_recording_id: Option<String>,
    pub mb_work_id: Option<String>,
    pub mb_release_id: Option<String>,
    pub mb_release_group_id: Option<String>,
    pub has_embedded_cover: bool,
    /// FLAC 内嵌 CUE 表（Vorbis 注释 `CUESHEET` 文本）。
    pub embedded_cuesheet: Option<String>,
}

fn clean(s: &str) -> Option<String> {
    let t = s.trim().trim_matches('\0').trim();
    (!t.is_empty()).then(|| t.to_owned())
}

fn get(tag: &Tag, key: &ItemKey) -> Option<String> {
    tag.get_string(key).and_then(clean)
}

fn get_all(tag: &Tag, key: &ItemKey) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for v in tag.get_strings(key) {
        // ID3v2.4 多值用 NUL 分隔；lofty 有时交回整串。
        for part in v.split('\0') {
            if let Some(c) = clean(part) {
                if !out.contains(&c) {
                    out.push(c);
                }
            }
        }
    }
    out
}

/// ReplayGain 值（`-7.25 dB` / `0.987654`）。
pub fn parse_rg(s: &str) -> Option<f64> {
    let t = s.trim();
    let t = t
        .strip_suffix("dB")
        .or_else(|| t.strip_suffix("db"))
        .or_else(|| t.strip_suffix("DB"))
        .unwrap_or(t);
    t.trim().parse::<f64>().ok().filter(|v| v.is_finite())
}

/// R128 增益（Opus `R128_TRACK_GAIN` / `R128_ALBUM_GAIN`，RFC 7845 §5.2.1）：Q7.8 定点整数，
/// 参考响度 -23 LUFS。ReplayGain 2.0 参考 -18 LUFS，所以换算成 RG dB 要再加 5。
pub fn parse_r128(s: &str) -> Option<f64> {
    let q: i32 = s.trim().parse().ok()?;
    if !(i16::MIN as i32..=i16::MAX as i32).contains(&q) {
        return None;
    }
    Some(q as f64 / 256.0 + 5.0)
}

/// Apple Sound Check（`iTunNORM`）：10 个 8 位十六进制数。前两个是左 / 右声道以 1/1000 W
/// 计的响度比，换算 `gain = -10·log10(max(v0, v1) / 1000)`（与 ReplayGain → Sound Check
/// 的通行写法 `v = 1000·10^(-gain/10)` 互逆）；第 7、8 个是左 / 右声道峰值样本（16 bit
/// 满幅 32768），取大者除以 32768 作线性峰值。返回 (gain dB, peak)。
pub fn parse_itunnorm(s: &str) -> Option<(f64, Option<f64>)> {
    let vals: Vec<u32> = s
        .split_whitespace()
        .map(|p| u32::from_str_radix(p, 16))
        .collect::<Result<Vec<u32>, _>>()
        .ok()?;
    if vals.len() < 2 {
        return None;
    }
    let loud = vals[0].max(vals[1]);
    if loud == 0 {
        return None;
    }
    let gain = -10.0 * (loud as f64 / 1000.0).log10();
    let peak = (vals.len() >= 8)
        .then(|| vals[6].max(vals[7]))
        .filter(|p| *p > 0)
        .map(|p| p as f64 / 32768.0);
    gain.is_finite().then_some((gain, peak))
}

/// 标签里不在 lofty 映射表中的键（MP4 自由格式 `----:com.apple.iTunes:<名>` 大小写变体、
/// Vorbis 的 `R128_*`）：按名字大小写不敏感找。
fn get_unknown(tag: &Tag, name: &str) -> Option<String> {
    tag.items().find_map(|item| {
        let ItemKey::Unknown(k) = item.key() else {
            return None;
        };
        let bare = k
            .strip_prefix("----:com.apple.iTunes:")
            .or_else(|| k.strip_prefix("TXXX:"))
            .unwrap_or(k);
        if bare.eq_ignore_ascii_case(name) {
            item.value().text().and_then(clean)
        } else {
            None
        }
    })
}

fn rg_value(tag: &Tag, key: &ItemKey, name: &str) -> Option<f64> {
    get(tag, key)
        .or_else(|| get_unknown(tag, name))
        .and_then(|s| parse_rg(&s))
}

/// 响度标签（设计 §7.3），优先级：ReplayGain 2.0 `REPLAYGAIN_*` > Opus `R128_*` > Apple
/// `iTunNORM`（只有曲目级）。缺的留 None，由 app 侧 EBU R128 扫描补。
pub fn fill_loudness(tag: &Tag, meta: &mut FileMeta) {
    meta.rg_track_gain = rg_value(tag, &ItemKey::ReplayGainTrackGain, "REPLAYGAIN_TRACK_GAIN");
    meta.rg_track_peak = rg_value(tag, &ItemKey::ReplayGainTrackPeak, "REPLAYGAIN_TRACK_PEAK");
    meta.rg_album_gain = rg_value(tag, &ItemKey::ReplayGainAlbumGain, "REPLAYGAIN_ALBUM_GAIN");
    meta.rg_album_peak = rg_value(tag, &ItemKey::ReplayGainAlbumPeak, "REPLAYGAIN_ALBUM_PEAK");
    if meta.rg_track_gain.is_none() {
        meta.rg_track_gain = get_unknown(tag, "R128_TRACK_GAIN").and_then(|s| parse_r128(&s));
    }
    if meta.rg_album_gain.is_none() {
        meta.rg_album_gain = get_unknown(tag, "R128_ALBUM_GAIN").and_then(|s| parse_r128(&s));
    }
    if meta.rg_track_gain.is_none() {
        if let Some((gain, peak)) = get_unknown(tag, "iTunNORM").and_then(|s| parse_itunnorm(&s)) {
            meta.rg_track_gain = Some(gain);
            if meta.rg_track_peak.is_none() {
                meta.rg_track_peak = peak;
            }
        }
    }
}

/// MP3 的 ID3v2：`TXXX` 描述大小写不规范（`replaygain_track_gain`）与 `COMM:iTunNORM`
/// 在 lofty 的通用 [`Tag`] 里拿不到，直接读 ID3v2 帧补。
fn fill_loudness_from_id3v2(path: &Path, meta: &mut FileMeta) {
    let Ok(f) = File::open(path) else { return };
    let mut reader = BufReader::new(f);
    let Ok(mp3) = MpegFile::read_from(&mut reader, ParseOptions::new().read_cover_art(false))
    else {
        return;
    };
    let Some(id3) = mp3.id3v2() else { return };
    let user = |name: &str| -> Option<f64> {
        id3.get_user_text(name)
            .or_else(|| id3.get_user_text(&name.to_ascii_lowercase()))
            .and_then(parse_rg)
    };
    meta.rg_track_gain = meta.rg_track_gain.or_else(|| user("REPLAYGAIN_TRACK_GAIN"));
    meta.rg_track_peak = meta.rg_track_peak.or_else(|| user("REPLAYGAIN_TRACK_PEAK"));
    meta.rg_album_gain = meta.rg_album_gain.or_else(|| user("REPLAYGAIN_ALBUM_GAIN"));
    meta.rg_album_peak = meta.rg_album_peak.or_else(|| user("REPLAYGAIN_ALBUM_PEAK"));
    if meta.rg_track_gain.is_none() {
        let norm = id3
            .comments()
            .find(|c| c.description.eq_ignore_ascii_case("iTunNORM"))
            .and_then(|c| parse_itunnorm(&c.content));
        if let Some((gain, peak)) = norm {
            meta.rg_track_gain = Some(gain);
            if meta.rg_track_peak.is_none() {
                meta.rg_track_peak = peak;
            }
        }
    }
}

/// 日期串里的年份（`2019`、`2019-03-01`、`2019/03`）。
pub fn year_of(s: &str) -> Option<i64> {
    let digits: String = s.trim().chars().take(4).collect();
    (digits.len() == 4 && digits.chars().all(|c| c.is_ascii_digit()))
        .then(|| digits.parse().ok())
        .flatten()
}

/// `3/12` 这种「序号/总数」只取前面。
fn leading_number(s: &str) -> Option<i64> {
    s.trim().split('/').next()?.trim().parse().ok()
}

fn codec_of(file_type: FileType) -> (&'static str, bool) {
    match file_type {
        FileType::Flac => ("flac", true),
        FileType::Ape => ("ape", true),
        FileType::WavPack => ("wavpack", true),
        FileType::Wav => ("pcm", true),
        FileType::Aiff => ("pcm", true),
        FileType::Mpeg => ("mp3", false),
        FileType::Aac => ("aac", false),
        FileType::Mp4 => ("aac", false),
        FileType::Mpc => ("musepack", false),
        FileType::Opus => ("opus", false),
        FileType::Vorbis => ("vorbis", false),
        FileType::Speex => ("speex", false),
        _ => ("unknown", false),
    }
}

/// lofty 不认的扩展名 → （编码, 是否无损）。
fn codec_of_extension(ext: &str) -> Option<(&'static str, bool)> {
    Some(match ext {
        "tak" => ("tak", true),
        "tta" => ("tta", true),
        "dsf" | "dff" => ("dsd", true),
        "w64" => ("pcm", true),
        "caf" => ("caf", false),
        "mka" => ("matroska", false),
        "wma" => ("wma", false),
        _ => return None,
    })
}

/// 读一个文件的标签与属性。lofty 读不了的格式不报错，退化为扩展名推断（标题由调用方
/// 用文件名补）；真正打不开（权限 / IO）才返回 Err。
pub fn read_file_meta(path: &Path) -> Result<FileMeta, String> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();

    if ext == "dsf" {
        let mut head = [0u8; 80];
        let mut f = File::open(path).map_err(|e| e.to_string())?;
        let n = f.read(&mut head).map_err(|e| e.to_string())?;
        let mut meta = FileMeta {
            codec: Some("dsd".into()),
            is_lossless: true,
            bit_depth: Some(1),
            ..Default::default()
        };
        if let Some(info) = dsf::parse_header(&head[..n]) {
            meta.sample_rate = Some(info.sample_rate as i64);
            meta.channels = Some(info.channels as i64);
            meta.duration_ms = Some(info.duration_ms);
            meta.bitrate_kbps = Some(info.sample_rate as i64 * info.channels as i64 / 1000);
        }
        return Ok(meta);
    }

    let probe = Probe::open(path)
        .map_err(|e| e.to_string())?
        .options(ParseOptions::new())
        .guess_file_type()
        .map_err(|e| e.to_string())?;
    let Some(file_type) = probe.file_type() else {
        // lofty 认不出的容器（TAK / TTA / MKA ...）：扩展名定编码。
        let (codec, lossless) = codec_of_extension(&ext).unwrap_or(("unknown", false));
        return Ok(FileMeta {
            codec: Some(codec.into()),
            is_lossless: lossless,
            ..Default::default()
        });
    };
    // 解析失败（坏文件 / 截断 / 伪装扩展名）如实报错：扫描器记一条错误记录、不入库，
    // 不把读不出来的东西当成「无标签的歌」塞进曲库。
    let tagged = probe.read().map_err(|e| e.to_string())?;

    let (mut codec, mut lossless) = codec_of(file_type);
    if file_type == FileType::Mp4 {
        // MP4 里装的是 ALAC 还是 AAC 只有 mp4 专用属性知道。
        if let Ok(f) = File::open(path) {
            let mut reader = BufReader::new(f);
            if let Ok(mp4) =
                Mp4File::read_from(&mut reader, ParseOptions::new().read_cover_art(false))
            {
                if matches!(mp4.properties().codec(), Mp4Codec::ALAC) {
                    codec = "alac";
                    lossless = true;
                }
            }
        }
    }

    let props = tagged.properties();
    let duration = props.duration().as_millis() as i64;
    let mut meta = FileMeta {
        codec: Some(codec.into()),
        is_lossless: lossless,
        duration_ms: (duration > 0).then_some(duration),
        sample_rate: props.sample_rate().map(i64::from),
        bit_depth: props.bit_depth().map(i64::from),
        channels: props.channels().map(i64::from),
        bitrate_kbps: props
            .audio_bitrate()
            .or_else(|| props.overall_bitrate())
            .map(i64::from),
        ..Default::default()
    };
    if !lossless {
        // 有损编码没有「位深」概念（解码器内部精度不是源属性），不报。
        meta.bit_depth = None;
    }

    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(meta);
    };
    meta.title = tag.title().and_then(|s| clean(&s));
    meta.title_sort = get(tag, &ItemKey::TrackTitleSortOrder);
    meta.artists = get_all(tag, &ItemKey::TrackArtist);
    meta.album = tag.album().and_then(|s| clean(&s));
    meta.album_sort = get(tag, &ItemKey::AlbumTitleSortOrder);
    meta.album_artist = get(tag, &ItemKey::AlbumArtist);
    meta.composers = get_all(tag, &ItemKey::Composer);
    meta.lyricists = get_all(tag, &ItemKey::Lyricist);
    meta.arrangers = get_all(tag, &ItemKey::Arranger);
    meta.track_no = tag
        .track()
        .map(i64::from)
        .or_else(|| get(tag, &ItemKey::TrackNumber).and_then(|s| leading_number(&s)));
    meta.disc_no = tag
        .disk()
        .map(i64::from)
        .or_else(|| get(tag, &ItemKey::DiscNumber).and_then(|s| leading_number(&s)));
    meta.disc_total = tag.disk_total().map(i64::from);
    meta.release_date = get(tag, &ItemKey::RecordingDate)
        .or_else(|| get(tag, &ItemKey::ReleaseDate))
        .or_else(|| get(tag, &ItemKey::Year));
    meta.year = meta
        .release_date
        .as_deref()
        .and_then(year_of)
        .or_else(|| tag.year().map(i64::from));
    meta.genre = tag.genre().and_then(|s| clean(&s));
    meta.catalog_no = get(tag, &ItemKey::CatalogNumber);
    fill_loudness(tag, &mut meta);
    if file_type == FileType::Mpeg && (meta.rg_track_gain.is_none() || meta.rg_album_gain.is_none())
    {
        fill_loudness_from_id3v2(path, &mut meta);
    }
    meta.mb_recording_id = get(tag, &ItemKey::MusicBrainzRecordingId);
    meta.mb_work_id = get(tag, &ItemKey::MusicBrainzWorkId);
    meta.mb_release_id = get(tag, &ItemKey::MusicBrainzReleaseId);
    meta.mb_release_group_id = get(tag, &ItemKey::MusicBrainzReleaseGroupId);
    meta.embedded_cuesheet = tag
        .get_string(&ItemKey::Unknown("CUESHEET".into()))
        .and_then(clean);
    meta.has_embedded_cover = tagged.tags().iter().any(|t| !t.pictures().is_empty());
    Ok(meta)
}

/// 内嵌封面字节：优先 front cover，没有就取第一张。
pub fn embedded_cover(path: &Path) -> Result<Option<Vec<u8>>, String> {
    let tagged = match Probe::open(path)
        .map_err(|e| e.to_string())?
        .guess_file_type()
        .map_err(|e| e.to_string())?
        .read()
    {
        Ok(t) => t,
        Err(_) => return Ok(None),
    };
    for tag in tagged.tags() {
        let pics = tag.pictures();
        if let Some(p) = pics
            .iter()
            .find(|p| p.pic_type() == PictureType::CoverFront)
            .or_else(|| pics.first())
        {
            return Ok(Some(p.data().to_vec()));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rg_and_year_parsing() {
        assert_eq!(parse_rg("-7.25 dB"), Some(-7.25));
        assert_eq!(parse_rg("+1.00 dB"), Some(1.0));
        assert_eq!(parse_rg("0.987654"), Some(0.987654));
        assert_eq!(parse_rg("x"), None);
        assert_eq!(year_of("2019-03-01"), Some(2019));
        assert_eq!(year_of("19"), None);
        assert_eq!(leading_number("3/12"), Some(3));
    }

    #[test]
    fn r128_to_replaygain() {
        // Q7.8：-2048/256 = -8 dB（相对 -23 LUFS）→ RG2（-18 LUFS）= -3 dB。
        assert_eq!(parse_r128("-2048"), Some(-3.0));
        assert_eq!(parse_r128("0"), Some(5.0));
        assert_eq!(parse_r128(" 256 "), Some(6.0));
        assert_eq!(parse_r128("40000"), None);
        assert_eq!(parse_r128("-3.5"), None);
    }

    #[test]
    fn itunnorm_to_replaygain() {
        // 0x3E8 = 1000 → 0 dB；0x2710 = 10000 → -10 dB；峰值 0x4000 / 32768 = 0.5。
        let (g, p) = parse_itunnorm(
            " 000003E8 00000200 00000000 00000000 00000000 00000000 00004000 00002000 00000000 00000000",
        )
        .unwrap();
        assert!(g.abs() < 1e-9);
        assert_eq!(p, Some(0.5));
        let (g, p) = parse_itunnorm("00000100 00002710").unwrap();
        assert!((g + 10.0).abs() < 1e-9);
        assert_eq!(p, None);
        assert_eq!(parse_itunnorm("zz"), None);
        assert_eq!(parse_itunnorm("00000000 00000000"), None);
    }

    #[test]
    fn loudness_precedence_and_unknown_keys() {
        use lofty::tag::{ItemValue, TagItem, TagType};
        let mut tag = Tag::new(TagType::VorbisComments);
        tag.push_unchecked(TagItem::new(
            ItemKey::Unknown("R128_TRACK_GAIN".into()),
            ItemValue::Text("-2048".into()),
        ));
        tag.push_unchecked(TagItem::new(
            ItemKey::Unknown("R128_ALBUM_GAIN".into()),
            ItemValue::Text("0".into()),
        ));
        let mut meta = FileMeta::default();
        fill_loudness(&tag, &mut meta);
        assert_eq!(meta.rg_track_gain, Some(-3.0));
        assert_eq!(meta.rg_album_gain, Some(5.0));

        // REPLAYGAIN_* 优先于 R128_*。
        tag.push_unchecked(TagItem::new(
            ItemKey::ReplayGainTrackGain,
            ItemValue::Text("-6.50 dB".into()),
        ));
        fill_loudness(&tag, &mut meta);
        assert_eq!(meta.rg_track_gain, Some(-6.5));

        // MP4 自由格式大写变体（lofty 只映射小写）+ iTunNORM。
        let mut mp4 = Tag::new(TagType::Mp4Ilst);
        mp4.push_unchecked(TagItem::new(
            ItemKey::Unknown("----:com.apple.iTunes:REPLAYGAIN_ALBUM_GAIN".into()),
            ItemValue::Text("-1.25 dB".into()),
        ));
        mp4.push_unchecked(TagItem::new(
            ItemKey::Unknown("----:com.apple.iTunes:iTunNORM".into()),
            ItemValue::Text("00002710 00002710 0 0 0 0 00008000 00004000".into()),
        ));
        let mut meta = FileMeta::default();
        fill_loudness(&mp4, &mut meta);
        assert_eq!(meta.rg_album_gain, Some(-1.25));
        assert!((meta.rg_track_gain.unwrap() + 10.0).abs() < 1e-9);
        assert_eq!(meta.rg_track_peak, Some(1.0));
    }
}

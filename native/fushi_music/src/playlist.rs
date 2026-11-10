//! 播放列表文件（`.m3u` / `.m3u8`）解析：曲库扫描时顺带认出来、导入时手动选的文件都走这里。
//!
//! 只做文本层：解出列表名（`#PLAYLIST:`）与条目，把条目换成**与曲库同一种拼法**的绝对路径
//! （相对路径按列表文件所在目录拼、`.` / `..` 按词法消掉，再经
//! [crate::scan::canonical_track_path]），Dart 拿去按路径键对曲库。网络地址（`http://` 等）
//! 原样交回，由 Dart 决定怎么处理。
//!
//! 编码：`.m3u8` 按规范是 UTF-8；老 `.m3u` 常是本地代码页（日文 Shift_JIS 最常见），与 CUE
//! 同一套判法（[crate::cue::decode_text]）。

use std::path::{Component, Path, PathBuf};

use crate::cue;
use crate::scan::canonical_track_path;
use crate::wire::{Reader, Writer};

/// 曲库扫描认作播放列表的扩展名（小写）。
pub const PLAYLIST_EXTENSIONS: &[&str] = &["m3u", "m3u8"];

pub fn is_playlist_extension(ext: &str) -> bool {
    PLAYLIST_EXTENSIONS.contains(&ext)
}

/// 一份解析好的播放列表。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ParsedPlaylist {
    /// `#PLAYLIST:` 给的名字；没写为 None（调用方用文件名）。
    pub name: Option<String>,

    /// 条目（列表顺序，可重复）：本地文件是绝对路径，网络地址原样。
    pub entries: Vec<String>,
}

/// 解析列表文件的原始字节。[base_dir] 是列表文件所在目录（相对条目按它拼）；None 时相对
/// 条目原样交回。
pub fn parse(bytes: &[u8], base_dir: Option<&Path>) -> ParsedPlaylist {
    let text = cue::decode_text(bytes);
    let mut out = ParsedPlaylist::default();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix('#') {
            if let Some(name) = rest.strip_prefix("PLAYLIST:") {
                let name = name.trim();
                if !name.is_empty() && out.name.is_none() {
                    out.name = Some(name.to_owned());
                }
            }
            continue;
        }
        if let Some(entry) = resolve_entry(line, base_dir) {
            out.entries.push(entry);
        }
    }
    out
}

/// 一行条目 → 交给 Dart 的串。
fn resolve_entry(line: &str, base_dir: Option<&Path>) -> Option<String> {
    if let Some(rest) = strip_prefix_ignore_case(line, "file://") {
        return Some(local_path(&file_uri_path(rest), None));
    }
    if has_url_scheme(line) {
        return Some(line.to_owned());
    }
    Some(local_path(line, base_dir))
}

/// 本地条目 → 绝对、统一拼法的路径串。
fn local_path(entry: &str, base_dir: Option<&Path>) -> String {
    let entry = platform_separators(entry);
    let p = Path::new(&entry);
    let joined = if p.is_absolute() || looks_windows_absolute(&entry) {
        p.to_path_buf()
    } else {
        match base_dir {
            Some(base) => base.join(p),
            None => return entry,
        }
    };
    canonical_track_path(&lexical_normalize(&joined))
        .to_string_lossy()
        .into_owned()
}

/// 别的系统写的列表：Windows 上统一成 `\`；其它系统把 `\` 当分隔符（Windows 写的列表
/// 拿到 Android / Linux 上读）。
fn platform_separators(entry: &str) -> String {
    if cfg!(windows) {
        entry.replace('/', "\\")
    } else {
        entry.replace('\\', "/")
    }
}

/// `C:\…` / `C:/…`：非 Windows 上 [Path::is_absolute] 不认，但它显然不是相对路径，
/// 不能拼到列表目录后面（Dart 再按尾段去对曲库）。
fn looks_windows_absolute(entry: &str) -> bool {
    let b = entry.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'/' || b[2] == b'\\')
}

/// 消掉 `.` 与 `..`（只按词法，不碰文件系统；`..` 越过根时停在根）。
fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                let at_root = matches!(
                    out.components().next_back(),
                    None | Some(Component::RootDir) | Some(Component::Prefix(_))
                );
                if !at_root {
                    out.pop();
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// `scheme://`（至少两个字母，排除 `C:/` 这类盘符）。
fn has_url_scheme(line: &str) -> bool {
    let Some(i) = line.find("://") else {
        return false;
    };
    i >= 2
        && line[..i]
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
}

fn strip_prefix_ignore_case<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    let head = s.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &s[prefix.len()..])
}

/// `file://` 之后的部分 → 路径：去掉主机名（通常为空或 `localhost`）、百分号解码，
/// Windows 的 `/C:/x` 去掉开头的 `/`。
fn file_uri_path(rest: &str) -> String {
    let path = match rest.find('/') {
        Some(0) => rest,
        Some(i) => &rest[i..],
        None => rest,
    };
    let decoded = percent_decode(path);
    let b = decoded.as_bytes();
    if b.len() >= 3 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b':' {
        return decoded[1..].to_owned();
    }
    decoded
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// 交给 Dart 的编码：`opt_str name | u32 count | str entry*count`（批次里的播放列表记录
/// 与 [crate::ffm_playlist_parse] 的输出共用这一段）。
pub fn write_parsed(w: &mut Writer, p: &ParsedPlaylist) {
    w.opt_str(p.name.as_deref());
    w.u32(p.entries.len() as u32);
    for e in &p.entries {
        w.str(e);
    }
}

pub fn read_parsed(r: &mut Reader<'_>) -> Option<ParsedPlaylist> {
    let name = r.opt_str()?;
    let count = r.u32()? as usize;
    let mut entries = Vec::with_capacity(count.min(1 << 16));
    for _ in 0..count {
        entries.push(r.str()?);
    }
    Some(ParsedPlaylist { name, entries })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> PathBuf {
        if cfg!(windows) {
            PathBuf::from(r"D:\Music\Lists")
        } else {
            PathBuf::from("/music/Lists")
        }
    }

    fn native(p: &str) -> String {
        if cfg!(windows) {
            format!("D:{}", p.replace('/', "\\"))
        } else {
            format!("/music{}", p.strip_prefix("/Music").unwrap_or(p))
        }
    }

    #[test]
    fn extended_m3u_with_name_relative_and_parent_entries() {
        let text = "\u{feff}#EXTM3U\n#PLAYLIST:Night Drive\n#EXTINF:215,A - B\n../Album/01 B.flac\n\n./02.mp3\r\nsub\\03.m4a\n";
        let p = parse(text.as_bytes(), Some(&base()));
        assert_eq!(p.name.as_deref(), Some("Night Drive"));
        assert_eq!(
            p.entries,
            vec![
                native("/Music/Album/01 B.flac"),
                native("/Music/Lists/02.mp3"),
                native("/Music/Lists/sub/03.m4a"),
            ]
        );
    }

    #[test]
    fn file_uris_are_decoded_and_urls_kept() {
        let entry = if cfg!(windows) {
            "file:///D:/Music/My%20Song.flac"
        } else {
            "file:///music/My%20Song.flac"
        };
        let text = format!("{entry}\nhttps://example.com/stream.mp3\n");
        let p = parse(text.as_bytes(), Some(&base()));
        assert_eq!(p.name, None);
        assert_eq!(
            p.entries,
            vec![
                native("/Music/My Song.flac"),
                "https://example.com/stream.mp3".to_owned()
            ]
        );
    }

    #[test]
    fn windows_absolute_entries_are_not_joined_to_the_list_dir() {
        let p = parse(br"C:\Users\x\Music\a.flac", Some(&base()));
        assert_eq!(p.entries.len(), 1);
        assert!(p.entries[0].contains("Users"));
        assert!(!p.entries[0].contains("Lists"));
    }

    #[test]
    fn shift_jis_m3u_decodes() {
        // 「曲.mp3」的 Shift_JIS。
        let bytes = [0x8B, 0xC8, b'.', b'm', b'p', b'3'];
        let p = parse(&bytes, Some(&base()));
        assert_eq!(p.entries, vec![native("/Music/Lists/曲.mp3")]);
    }

    #[test]
    fn parent_dir_never_climbs_past_root() {
        let root = if cfg!(windows) { r"D:\" } else { "/" };
        let p = parse(b"../../x.mp3", Some(Path::new(root)));
        assert_eq!(
            p.entries,
            vec![if cfg!(windows) {
                r"D:\x.mp3".to_owned()
            } else {
                "/x.mp3".to_owned()
            }]
        );
    }

    #[test]
    fn encoding_round_trips() {
        let p = ParsedPlaylist {
            name: Some("名".into()),
            entries: vec!["a".into(), "b".into()],
        };
        let mut w = Writer::new();
        write_parsed(&mut w, &p);
        let bytes = w.into_bytes();
        let mut r = Reader::new(&bytes);
        assert_eq!(read_parsed(&mut r), Some(p));
        assert!(r.at_end());
    }
}

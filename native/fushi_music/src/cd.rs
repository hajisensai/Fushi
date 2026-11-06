//! 音频 CD（音乐方案 §9.2）：TOC → MusicBrainz Disc ID、CD-TEXT 解析、桌面光驱读 TOC /
//! CD-TEXT。
//!
//! 统一输入形态是 **MMC `READ TOC/PMA/ATIP` 的原始响应**：格式 0（TOC：4 字节头 + 每轨 8 字节
//! 描述符，地址为 LBA）与格式 5（CD-TEXT：4 字节头 + 每包 18 字节）。Windows 的
//! `IOCTL_CDROM_READ_TOC_EX` 原样返回这两种；Linux / macOS 的 ioctl 结果在 [device] 里换算成
//! 同一形态。于是解析与 Disc ID 只有一份实现，可用固定字节向量测（不需要光驱）。
//!
//! MusicBrainz Disc ID（<https://musicbrainz.org/doc/Disc_ID_Calculation>，libdiscid 同一算法）：
//! `SHA-1( "%02X"首轨 "%02X"末轨 "%08X"lead-out "%08X"×99 各轨偏移 )`，偏移是 LBA + 150，
//! 没有的轨位填 0；结果做 base64，`+ / =` 换成 `. _ -`。Enhanced CD（末尾是数据轨，第二个
//! session）只算音频轨：末轨取最后一条音频轨，lead-out = 数据轨起点 − 11400（session 间隙）。

use sha1::{Digest, Sha1};

/// TOC 里的一轨。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TocTrack {
    pub number: u8,
    /// 起点 LBA（不含 150 帧的前导间隙）。
    pub lba: u32,
    /// CONTROL 位 0x04：数据轨。
    pub is_data: bool,
}

/// 整张盘的 TOC。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toc {
    pub first: u8,
    pub last: u8,
    pub tracks: Vec<TocTrack>,
    /// lead-out LBA（最后一个 session 的）。
    pub leadout: u32,
}

/// 两个 session 之间的间隙（帧）：lead-out 6750 + lead-in 4500 + pregap 150（红皮书 / libdiscid）。
pub const SESSION_GAP_FRAMES: u32 = 11400;

/// 前导间隙：LBA 0 对应绝对地址 00:02:00。
pub const PREGAP_FRAMES: u32 = 150;

fn be16(b: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*b.get(at)?, *b.get(at + 1)?]))
}

fn be32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes([
        *b.get(at)?,
        *b.get(at + 1)?,
        *b.get(at + 2)?,
        *b.get(at + 3)?,
    ]))
}

/// 解析 MMC READ TOC 格式 0（LBA 地址）的原始响应。结构不合法返回 None。
pub fn parse_toc(raw: &[u8]) -> Option<Toc> {
    let len = be16(raw, 0)? as usize; // 不含这 2 字节本身
    let first = *raw.get(2)?;
    let last = *raw.get(3)?;
    let end = (len + 2).min(raw.len());
    if first == 0 || last < first || last > 99 {
        return None;
    }
    let mut tracks = Vec::new();
    let mut leadout = None;
    let mut at = 4;
    while at + 8 <= end {
        let control = raw[at + 1] & 0x0F;
        let number = raw[at + 2];
        let lba = be32(raw, at + 4)?;
        if number == 0xAA {
            leadout = Some(lba);
        } else if (1..=99).contains(&number) {
            tracks.push(TocTrack {
                number,
                lba,
                is_data: control & 0x04 != 0,
            });
        }
        at += 8;
    }
    let leadout = leadout?;
    if tracks.is_empty() {
        return None;
    }
    tracks.sort_by_key(|t| t.number);
    // 地址必须单调、都在 lead-out 之前，否则是坏响应（或驱动给了 MSF 当 LBA）。
    if tracks.windows(2).any(|w| w[1].lba <= w[0].lba) || tracks.last()?.lba >= leadout {
        return None;
    }
    Some(Toc {
        first,
        last,
        tracks,
        leadout,
    })
}

/// 音频部分（MusicBrainz 口径）：(首轨, 末轨, lead-out LBA, 各音频轨)。没有音频轨返回 None。
pub fn audio_session(toc: &Toc) -> Option<(u8, u8, u32, Vec<&TocTrack>)> {
    let audio: Vec<&TocTrack> = toc.tracks.iter().filter(|t| !t.is_data).collect();
    let first = audio.first()?.number;
    let last = audio.last()?.number;
    // 末轨之后还有数据轨（Enhanced CD）：音频部分的 lead-out 是数据轨起点减 session 间隙。
    let leadout = match toc.tracks.iter().find(|t| t.is_data && t.number > last) {
        Some(data) => data.lba.checked_sub(SESSION_GAP_FRAMES)?,
        None => toc.leadout,
    };
    Some((first, last, leadout, audio))
}

/// MusicBrainz Disc ID 与 ws/2 `toc=` 查询串（`首轨 末轨 lead-out 偏移…`，偏移含 150）。
pub fn musicbrainz_disc_id(toc: &Toc) -> Option<(String, String)> {
    let (first, last, leadout, audio) = audio_session(toc)?;
    let mut offsets = [0u32; 100];
    offsets[0] = leadout + PREGAP_FRAMES;
    for t in &audio {
        offsets[t.number as usize] = t.lba + PREGAP_FRAMES;
    }
    let mut text = format!("{first:02X}{last:02X}");
    for o in offsets.iter() {
        text.push_str(&format!("{o:08X}"));
    }
    let digest = Sha1::digest(text.as_bytes());
    let id: String = data_encoding::BASE64
        .encode(&digest)
        .chars()
        .map(|c| match c {
            '+' => '.',
            '/' => '_',
            '=' => '-',
            c => c,
        })
        .collect();
    let mut toc_str = format!("{first} {last} {}", leadout + PREGAP_FRAMES);
    for t in &audio {
        toc_str.push_str(&format!(" {}", t.lba + PREGAP_FRAMES));
    }
    Some((id, toc_str))
}

/// CD-TEXT 字段（包类型）。
pub mod cdtext_field {
    pub const TITLE: u8 = 0x80;
    pub const PERFORMER: u8 = 0x81;
    pub const SONGWRITER: u8 = 0x82;
    pub const COMPOSER: u8 = 0x83;
    pub const ARRANGER: u8 = 0x84;
    pub const MESSAGE: u8 = 0x85;
    /// UPC / EAN（轨 0）与 ISRC（各轨）。
    pub const UPC_ISRC: u8 = 0x8E;
    /// 块大小信息（第 0 字节是字符集）。
    pub const SIZE_INFO: u8 = 0x8F;
}

/// 一条 CD-TEXT：轨号（0 = 整张盘）+ 字段 + 文本。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CdTextEntry {
    pub track: u8,
    pub field: u8,
    pub value: String,
}

/// CD-TEXT 包的 CRC-16（CCITT，多项式 0x1021，初值 0，结果按位取反存放）。
fn cdtext_crc_ok(pack: &[u8]) -> bool {
    let mut crc: u16 = 0;
    for &byte in &pack[..16] {
        crc ^= (byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    let stored = u16::from_be_bytes([pack[16], pack[17]]);
    (!crc) == stored
}

fn decode_cdtext(bytes: &[u8], charset: u8) -> String {
    match charset {
        // MS-JIS（日本盘）。
        0x80 => encoding_rs::SHIFT_JIS.decode(bytes).0.into_owned(),
        // 0x00 ISO-8859-1、0x01 ISO-646（ASCII），以及规范外的值都按 Latin-1 读。
        _ => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// 解析 MMC READ TOC 格式 5（CD-TEXT）的原始响应。只取第 0 块（第一种语言）；CRC 不对的包
/// 丢掉（有的驱动不填 CRC：全部包都校验失败时改为不校验）。
pub fn parse_cdtext(raw: &[u8]) -> Vec<CdTextEntry> {
    let Some(len) = be16(raw, 0) else {
        return Vec::new();
    };
    let end = (len as usize + 2).min(raw.len());
    if end <= 4 {
        return Vec::new();
    }
    let packs: Vec<&[u8]> = raw[4..end].chunks_exact(18).collect();
    let any_crc_ok = packs.iter().any(|p| cdtext_crc_ok(p));
    let block0: Vec<&[u8]> = packs
        .into_iter()
        .filter(|p| (p[3] >> 4) & 0x07 == 0)
        .filter(|p| !any_crc_ok || cdtext_crc_ok(p))
        .collect();
    let charset = block0
        .iter()
        .find(|p| p[0] == cdtext_field::SIZE_INFO)
        .map(|p| p[4])
        .unwrap_or(0);
    let mut out: Vec<CdTextEntry> = Vec::new();
    for field in [
        cdtext_field::TITLE,
        cdtext_field::PERFORMER,
        cdtext_field::SONGWRITER,
        cdtext_field::COMPOSER,
        cdtext_field::ARRANGER,
        cdtext_field::MESSAGE,
        cdtext_field::UPC_ISRC,
    ] {
        let mut of_type: Vec<&[u8]> = block0.iter().copied().filter(|p| p[0] == field).collect();
        if of_type.is_empty() {
            continue;
        }
        of_type.sort_by_key(|p| p[2]);
        let double_byte = of_type[0][3] & 0x80 != 0;
        let mut track = of_type[0][1] & 0x7F;
        let mut text: Vec<u8> = Vec::new();
        for p in of_type {
            text.extend_from_slice(&p[4..16]);
        }
        // 按 NUL（双字节字符集是双 NUL）切成逐轨文本；单个 TAB = 与上一轨相同。
        let mut previous = String::new();
        let mut cur: Vec<u8> = Vec::new();
        let mut i = 0;
        while i < text.len() {
            let terminator = if double_byte {
                i + 1 < text.len() && text[i] == 0 && text[i + 1] == 0
            } else {
                text[i] == 0
            };
            if terminator {
                let value = if cur == b"\t" || cur == b"\t\t" {
                    previous.clone()
                } else {
                    decode_cdtext(&cur, if double_byte { 0x80 } else { charset })
                        .trim()
                        .to_string()
                };
                if !value.is_empty() {
                    out.push(CdTextEntry {
                        track,
                        field,
                        value: value.clone(),
                    });
                }
                previous = value;
                cur.clear();
                track = track.saturating_add(1);
                i += if double_byte { 2 } else { 1 };
                continue;
            }
            cur.push(text[i]);
            i += 1;
        }
    }
    out
}

/// 一张盘的读取结果。
pub struct CdInfo {
    pub toc: Toc,
    pub disc_id: Option<String>,
    pub toc_query: Option<String>,
    pub cdtext: Vec<CdTextEntry>,
}

/// 原始 TOC + CD-TEXT 字节 → [CdInfo]。TOC 不合法返回 None。
pub fn info_from_raw(toc_raw: &[u8], cdtext_raw: &[u8]) -> Option<CdInfo> {
    let toc = parse_toc(toc_raw)?;
    let id = musicbrainz_disc_id(&toc);
    Some(CdInfo {
        disc_id: id.as_ref().map(|(i, _)| i.clone()),
        toc_query: id.map(|(_, q)| q),
        cdtext: parse_cdtext(cdtext_raw),
        toc,
    })
}

/// 每轨的长度（帧，1/75 s）：到下一轨起点；音频部分的末轨到音频 lead-out（Enhanced CD 的
/// 数据轨前有 11400 帧 session 间隙，不算进末首歌）；数据轨到盘的 lead-out。
pub fn track_lengths(toc: &Toc) -> Vec<u32> {
    let audio_leadout = audio_session(toc).map(|(_, _, l, _)| l);
    let last_audio = toc
        .tracks
        .iter()
        .filter(|t| !t.is_data)
        .map(|t| t.number)
        .max();
    toc.tracks
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let end = if Some(t.number) == last_audio {
                audio_leadout.unwrap_or(toc.leadout)
            } else {
                toc.tracks.get(i + 1).map(|n| n.lba).unwrap_or(toc.leadout)
            };
            end.saturating_sub(t.lba)
        })
        .collect()
}

/// 线格式（小端）：
/// `u32 版本=1 | u8 首轨 | u8 末轨 | u32 lead-out | u32 轨数 | 每轨 (u8 号, u8 数据轨, u32 LBA,
/// u32 长度帧) | str DiscID | str toc 查询串 | u32 CD-TEXT 条数 | 每条 (u8 轨, u8 字段, str 值)`，
/// `str` = `u32 字节数 + UTF-8`（取不到为空串）。
pub fn encode_info(info: &CdInfo) -> Vec<u8> {
    fn put_str(out: &mut Vec<u8>, s: &str) {
        out.extend_from_slice(&(s.len() as u32).to_le_bytes());
        out.extend_from_slice(s.as_bytes());
    }
    let mut out = Vec::new();
    out.extend_from_slice(&1u32.to_le_bytes());
    out.push(info.toc.first);
    out.push(info.toc.last);
    out.extend_from_slice(&info.toc.leadout.to_le_bytes());
    out.extend_from_slice(&(info.toc.tracks.len() as u32).to_le_bytes());
    for (t, len) in info.toc.tracks.iter().zip(track_lengths(&info.toc)) {
        out.push(t.number);
        out.push(t.is_data as u8);
        out.extend_from_slice(&t.lba.to_le_bytes());
        out.extend_from_slice(&len.to_le_bytes());
    }
    put_str(&mut out, info.disc_id.as_deref().unwrap_or(""));
    put_str(&mut out, info.toc_query.as_deref().unwrap_or(""));
    out.extend_from_slice(&(info.cdtext.len() as u32).to_le_bytes());
    for e in &info.cdtext {
        out.push(e.track);
        out.push(e.field);
        put_str(&mut out, &e.value);
    }
    out
}

/// 光驱列表线格式：`u32 个数 | 每个 str 设备`。
pub fn encode_drives(drives: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(drives.len() as u32).to_le_bytes());
    for d in drives {
        out.extend_from_slice(&(d.len() as u32).to_le_bytes());
        out.extend_from_slice(d.as_bytes());
    }
    out
}

/// 读光驱的错误。
#[derive(Debug)]
pub enum DeviceError {
    /// 本平台不支持读物理光驱（Android / iOS）。
    Unsupported,
    /// 打不开设备 / 盘不在 / 不是音频 CD（TOC 读不出）。
    Io(String),
}

/// 平台光驱读取：返回 (格式 0 TOC 原始响应, 格式 5 CD-TEXT 原始响应；没有 CD-TEXT 为空)。
pub mod device {
    use super::DeviceError;

    #[cfg(windows)]
    mod imp {
        use super::DeviceError;
        use std::ffi::c_void;

        type Handle = *mut c_void;
        const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
        const GENERIC_READ: u32 = 0x8000_0000;
        const FILE_SHARE_READ: u32 = 0x1;
        const FILE_SHARE_WRITE: u32 = 0x2;
        const OPEN_EXISTING: u32 = 3;
        const DRIVE_CDROM: u32 = 5;
        // CTL_CODE(IOCTL_CDROM_BASE = 2, 0x0015, METHOD_BUFFERED, FILE_READ_ACCESS)。
        const IOCTL_CDROM_READ_TOC_EX: u32 = (0x2 << 16) | (0x1 << 14) | (0x15 << 2);
        const FORMAT_TOC: u8 = 0;
        const FORMAT_CDTEXT: u8 = 5;

        #[link(name = "kernel32")]
        extern "system" {
            fn CreateFileW(
                name: *const u16,
                access: u32,
                share: u32,
                security: *mut c_void,
                disposition: u32,
                flags: u32,
                template: Handle,
            ) -> Handle;
            fn DeviceIoControl(
                device: Handle,
                code: u32,
                input: *mut c_void,
                input_len: u32,
                output: *mut c_void,
                output_len: u32,
                returned: *mut u32,
                overlapped: *mut c_void,
            ) -> i32;
            fn CloseHandle(handle: Handle) -> i32;
            fn GetLogicalDrives() -> u32;
            fn GetDriveTypeW(root: *const u16) -> u32;
            fn GetLastError() -> u32;
        }

        fn wide(s: &str) -> Vec<u16> {
            s.encode_utf16().chain(std::iter::once(0)).collect()
        }

        /// `E:` / `E:\` / `\\.\E:` → 盘符。
        fn drive_letter(device: &str) -> Option<char> {
            let d = device.trim_start_matches(r"\\.\");
            let c = d.chars().next()?;
            if c.is_ascii_alphabetic() && d[1..].starts_with(':') {
                Some(c.to_ascii_uppercase())
            } else {
                None
            }
        }

        pub fn list_drives() -> Vec<String> {
            let mask = unsafe { GetLogicalDrives() };
            let mut out = Vec::new();
            for i in 0..26u32 {
                if mask & (1 << i) == 0 {
                    continue;
                }
                let root = format!("{}:\\", (b'A' + i as u8) as char);
                if unsafe { GetDriveTypeW(wide(&root).as_ptr()) } == DRIVE_CDROM {
                    out.push(format!("{}:", (b'A' + i as u8) as char));
                }
            }
            out
        }

        fn ioctl_read_toc(h: Handle, format: u8, session_track: u8) -> Result<Vec<u8>, u32> {
            // CDROM_READ_TOC_EX：Format（低 4 位）| Reserved1:3 | Msf:1；SessionTrack；2 字节保留。
            let mut input: [u8; 4] = [format & 0x0F, session_track, 0, 0];
            // 输出长度要放得进 MMC 的 16 位分配长度：TOC 用 `sizeof(CDROM_TOC)`（804），
            // CD-TEXT 给 32 KB（规范上限约 2 KB × 8 块）。给 64 KB 会被类驱动拒掉。
            let mut out = vec![0u8; if format == FORMAT_TOC { 804 } else { 0x8000 }];
            let mut returned: u32 = 0;
            let ok = unsafe {
                DeviceIoControl(
                    h,
                    IOCTL_CDROM_READ_TOC_EX,
                    input.as_mut_ptr() as *mut c_void,
                    input.len() as u32,
                    out.as_mut_ptr() as *mut c_void,
                    out.len() as u32,
                    &mut returned,
                    std::ptr::null_mut(),
                )
            };
            if ok == 0 {
                return Err(unsafe { GetLastError() });
            }
            out.truncate(returned as usize);
            Ok(out)
        }

        pub fn read(device: &str) -> Result<(Vec<u8>, Vec<u8>), DeviceError> {
            let letter = drive_letter(device)
                .ok_or_else(|| DeviceError::Io(format!("not a drive: {device}")))?;
            let path = wide(&format!(r"\\.\{letter}:"));
            let h = unsafe {
                CreateFileW(
                    path.as_ptr(),
                    GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    std::ptr::null_mut(),
                    OPEN_EXISTING,
                    0,
                    std::ptr::null_mut(),
                )
            };
            if h == INVALID_HANDLE_VALUE {
                return Err(DeviceError::Io(format!(
                    "open {letter}: failed (error {})",
                    unsafe { GetLastError() }
                )));
            }
            let toc = ioctl_read_toc(h, FORMAT_TOC, 1);
            // 没有 CD-TEXT 的盘 / 不支持的驱动在这里报错：当作没有 CD-TEXT。
            let text = ioctl_read_toc(h, FORMAT_CDTEXT, 0).unwrap_or_default();
            unsafe { CloseHandle(h) };
            match toc {
                Ok(toc) => Ok((toc, text)),
                Err(code) => Err(DeviceError::Io(format!(
                    "read TOC of {letter}: failed (error {code}; no disc or not an audio CD?)"
                ))),
            }
        }
    }

    #[cfg(target_os = "linux")]
    mod imp {
        use super::DeviceError;
        use std::os::raw::{c_char, c_int, c_ulong};

        extern "C" {
            fn open(path: *const c_char, flags: c_int, ...) -> c_int;
            fn close(fd: c_int) -> c_int;
            fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
        }
        const O_RDONLY: c_int = 0;
        const O_NONBLOCK: c_int = 0o4000;
        const CDROMREADTOCHDR: c_ulong = 0x5305;
        const CDROMREADTOCENTRY: c_ulong = 0x5306;
        const CDROM_LBA: u8 = 0x01;
        const CDROM_LEADOUT: u8 = 0xAA;

        #[repr(C)]
        struct TocHdr {
            trk0: u8,
            trk1: u8,
        }

        #[repr(C)]
        struct TocEntry {
            track: u8,
            /// 低 4 位 adr、高 4 位 ctrl（GCC 小端位域）。
            adr_ctrl: u8,
            format: u8,
            /// `union cdrom_addr`：LBA 时是 int。
            addr: i32,
            datamode: u8,
        }

        pub fn list_drives() -> Vec<String> {
            let mut out = Vec::new();
            if let Ok(dir) = std::fs::read_dir("/dev") {
                for e in dir.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name.starts_with("sr") && name[2..].chars().all(|c| c.is_ascii_digit()) {
                        out.push(format!("/dev/{name}"));
                    }
                }
            }
            out.sort();
            out
        }

        pub fn read(device: &str) -> Result<(Vec<u8>, Vec<u8>), DeviceError> {
            let c = std::ffi::CString::new(device)
                .map_err(|_| DeviceError::Io(format!("bad device path: {device}")))?;
            let fd = unsafe { open(c.as_ptr(), O_RDONLY | O_NONBLOCK) };
            if fd < 0 {
                return Err(DeviceError::Io(format!("open {device} failed")));
            }
            let result = (|| {
                let mut hdr = TocHdr { trk0: 0, trk1: 0 };
                if unsafe { ioctl(fd, CDROMREADTOCHDR, &mut hdr as *mut TocHdr) } < 0 {
                    return Err(DeviceError::Io(format!(
                        "read TOC of {device} failed (no disc or not an audio CD?)"
                    )));
                }
                // 换算成 MMC 格式 0 的原始响应，与 Windows 同一条解析。
                let mut raw = vec![0u8, 0, hdr.trk0, hdr.trk1];
                let mut tracks: Vec<u8> = (hdr.trk0..=hdr.trk1).collect();
                tracks.push(CDROM_LEADOUT);
                for t in tracks {
                    let mut e = TocEntry {
                        track: t,
                        adr_ctrl: 0,
                        format: CDROM_LBA,
                        addr: 0,
                        datamode: 0,
                    };
                    if unsafe { ioctl(fd, CDROMREADTOCENTRY, &mut e as *mut TocEntry) } < 0 {
                        return Err(DeviceError::Io(format!(
                            "read TOC entry {t} of {device} failed"
                        )));
                    }
                    let ctrl = e.adr_ctrl >> 4;
                    let adr = e.adr_ctrl & 0x0F;
                    raw.extend_from_slice(&[0, (adr << 4) | ctrl, t, 0]);
                    raw.extend_from_slice(&(e.addr as u32).to_be_bytes());
                }
                let len = (raw.len() - 2) as u16;
                raw[0..2].copy_from_slice(&len.to_be_bytes());
                // CD-TEXT 在 Linux 上要走 SG_IO 发 MMC 命令，本轮未实现：返回空。
                Ok((raw, Vec::new()))
            })();
            unsafe { close(fd) };
            result
        }
    }

    #[cfg(target_os = "macos")]
    mod imp {
        use super::DeviceError;
        use std::ffi::c_void;
        use std::os::raw::{c_char, c_int, c_ulong};

        extern "C" {
            fn open(path: *const c_char, flags: c_int, ...) -> c_int;
            fn close(fd: c_int) -> c_int;
            fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
        }
        const O_RDONLY: c_int = 0;
        const O_NONBLOCK: c_int = 0x0004;
        const FORMAT_FULL_TOC: u8 = 0x02;
        const FORMAT_CDTEXT: u8 = 0x05;

        /// `dk_cd_read_toc_t`（IOKit/storage/IOCDMediaBSDClient.h）。
        #[repr(C)]
        struct ReadToc {
            format: u8,
            format_as_time: u8,
            reserved0: [u8; 5],
            address: u8,
            reserved1: [u8; 5],
            buffer_length: u16,
            buffer: *mut c_void,
        }
        // _IOWR('d', 160, dk_cd_read_toc_t)。
        const DKIOCCDREADTOC: c_ulong = 0xC000_0000
            | (((std::mem::size_of::<ReadToc>() as c_ulong) & 0x1FFF) << 16)
            | ((b'd' as c_ulong) << 8)
            | 160;

        fn read_toc(fd: c_int, format: u8) -> Option<Vec<u8>> {
            let mut buf = vec![0u8; 0xFFFF];
            let mut req = ReadToc {
                format,
                format_as_time: 0,
                reserved0: [0; 5],
                address: 0,
                reserved1: [0; 5],
                buffer_length: buf.len() as u16,
                buffer: buf.as_mut_ptr() as *mut c_void,
            };
            if unsafe { ioctl(fd, DKIOCCDREADTOC, &mut req as *mut ReadToc) } < 0 {
                return None;
            }
            let len = u16::from_be_bytes([buf[0], buf[1]]) as usize + 2;
            buf.truncate(len.min(req.buffer_length as usize).max(4));
            Some(buf)
        }

        pub fn list_drives() -> Vec<String> {
            // 整盘设备（diskN，不含分区 diskNsM）里 TOC 读得出来的就是光驱里的盘。
            let mut out = Vec::new();
            if let Ok(dir) = std::fs::read_dir("/dev") {
                for e in dir.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name.starts_with("rdisk") && name[5..].chars().all(|c| c.is_ascii_digit()) {
                        let path = format!("/dev/{name}");
                        if read(&path).is_ok() {
                            out.push(path);
                        }
                    }
                }
            }
            out.sort();
            out
        }

        /// 完整 TOC（格式 2，每描述符 11 字节，POINT 0xA0/0xA1/0xA2 给首轨 / 末轨 / lead-out，
        /// 1..99 给各轨起点 MSF）→ MMC 格式 0。
        fn full_toc_to_format0(full: &[u8]) -> Option<Vec<u8>> {
            let mut first = 0u8;
            let mut last = 0u8;
            let mut leadout: Option<u32> = None;
            let mut tracks: Vec<(u8, u8, u32)> = Vec::new();
            let msf = |m: u8, s: u8, f: u8| -> u32 {
                ((m as u32 * 60 + s as u32) * 75 + f as u32).saturating_sub(150)
            };
            let mut at = 4;
            while at + 11 <= full.len() {
                let d = &full[at..at + 11];
                let adr_ctrl = d[1];
                let point = d[3];
                match point {
                    0xA0 => first = d[8],
                    0xA1 => last = d[8],
                    // 多 session 盘每个 session 一个 A2：取最后一个。
                    0xA2 => leadout = Some(msf(d[8], d[9], d[10])),
                    1..=99 => tracks.push((point, adr_ctrl, msf(d[8], d[9], d[10]))),
                    _ => {}
                }
                at += 11;
            }
            let leadout = leadout?;
            tracks.sort_by_key(|t| t.0);
            tracks.dedup_by_key(|t| t.0);
            if let (Some(f), Some(l)) = (tracks.first(), tracks.last()) {
                first = first.max(1).min(f.0);
                last = last.max(l.0);
            }
            let mut raw = vec![0u8, 0, first, last];
            for (n, adr_ctrl, lba) in tracks
                .into_iter()
                .chain(std::iter::once((0xAA, 0x10, leadout)))
            {
                // 完整 TOC 的这个字节是 ADR（高 4 位）| CONTROL（低 4 位），与格式 0 同序。
                raw.extend_from_slice(&[0, adr_ctrl, n, 0]);
                raw.extend_from_slice(&lba.to_be_bytes());
            }
            let len = (raw.len() - 2) as u16;
            raw[0..2].copy_from_slice(&len.to_be_bytes());
            Some(raw)
        }

        pub fn read(device: &str) -> Result<(Vec<u8>, Vec<u8>), DeviceError> {
            let c = std::ffi::CString::new(device)
                .map_err(|_| DeviceError::Io(format!("bad device path: {device}")))?;
            let fd = unsafe { open(c.as_ptr(), O_RDONLY | O_NONBLOCK) };
            if fd < 0 {
                return Err(DeviceError::Io(format!("open {device} failed")));
            }
            let toc = read_toc(fd, FORMAT_FULL_TOC).and_then(|f| full_toc_to_format0(&f));
            let text = read_toc(fd, FORMAT_CDTEXT).unwrap_or_default();
            unsafe { close(fd) };
            toc.map(|t| (t, text)).ok_or_else(|| {
                DeviceError::Io(format!(
                    "read TOC of {device} failed (no disc or not an audio CD?)"
                ))
            })
        }
    }

    #[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
    mod imp {
        use super::DeviceError;

        pub fn list_drives() -> Vec<String> {
            Vec::new()
        }

        pub fn read(_device: &str) -> Result<(Vec<u8>, Vec<u8>), DeviceError> {
            Err(DeviceError::Unsupported)
        }
    }

    /// 本机光驱（Windows 盘符 `E:` / Linux `/dev/srN` / macOS 装着盘的 `/dev/rdiskN`）。
    pub fn list_drives() -> Vec<String> {
        imp::list_drives()
    }

    /// 读一张盘的 TOC 与 CD-TEXT 原始响应。
    pub fn read(device: &str) -> Result<(Vec<u8>, Vec<u8>), DeviceError> {
        imp::read(device)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MMC 格式 0 原始响应（LBA）。
    fn raw_toc(first: u8, last: u8, tracks: &[(u8, bool, u32)], leadout: u32) -> Vec<u8> {
        let mut raw = vec![0u8, 0, first, last];
        for &(n, data, lba) in tracks
            .iter()
            .chain(std::iter::once(&(0xAA, false, leadout)))
        {
            raw.extend_from_slice(&[0, 0x10 | if data { 0x04 } else { 0x00 }, n, 0]);
            raw.extend_from_slice(&lba.to_be_bytes());
        }
        let len = (raw.len() - 2) as u16;
        raw[0..2].copy_from_slice(&len.to_be_bytes());
        raw
    }

    /// MusicBrainz 文档（Disc ID Calculation）与 libdiscid 测试里的样例盘：22 轨，
    /// toc = `1 22 303602 150 9700 25887 …`，Disc ID `xUp1F2NkfP8s8jaeFn_Av3jNEI4-`。
    #[test]
    fn musicbrainz_reference_disc_id() {
        let offsets: [u32; 22] = [
            150, 9700, 25887, 39297, 53795, 63735, 77517, 94877, 107270, 123552, 135522, 148422,
            161197, 174790, 192022, 205545, 218010, 228700, 239590, 255470, 266932, 288750,
        ];
        let tracks: Vec<(u8, bool, u32)> = offsets
            .iter()
            .enumerate()
            .map(|(i, &o)| ((i + 1) as u8, false, o - 150))
            .collect();
        let toc = parse_toc(&raw_toc(1, 22, &tracks, 303602 - 150)).unwrap();
        let (id, query) = musicbrainz_disc_id(&toc).unwrap();
        assert_eq!(id, "xUp1F2NkfP8s8jaeFn_Av3jNEI4-");
        assert!(query.starts_with("1 22 303602 150 9700 "));
    }

    /// Enhanced CD：末尾的数据轨不计，lead-out = 数据轨起点 − 11400。
    #[test]
    fn enhanced_cd_excludes_data_track() {
        let toc = parse_toc(&raw_toc(
            1,
            3,
            &[(1, false, 0), (2, false, 20000), (3, true, 60000)],
            90000,
        ))
        .unwrap();
        let (first, last, leadout, audio) = audio_session(&toc).unwrap();
        assert_eq!(
            (first, last, leadout, audio.len()),
            (1, 2, 60000 - 11400, 2)
        );
        let (_, query) = musicbrainz_disc_id(&toc).unwrap();
        assert_eq!(query, format!("1 2 {} 150 20150", 60000 - 11400 + 150));
        assert_eq!(
            track_lengths(&toc),
            vec![20000, 60000 - 11400 - 20000, 30000]
        );
    }

    #[test]
    fn bad_toc_is_rejected() {
        assert!(parse_toc(&[0, 2, 1, 1]).is_none());
        // 地址倒退。
        assert!(parse_toc(&raw_toc(1, 2, &[(1, false, 500), (2, false, 100)], 900)).is_none());
        // 没有 lead-out。
        let mut raw = raw_toc(1, 1, &[(1, false, 0)], 100);
        raw.truncate(12);
        raw[0..2].copy_from_slice(&10u16.to_be_bytes());
        assert!(parse_toc(&raw).is_none());
    }

    fn pack(kind: u8, track: u8, seq: u8, block_flags: u8, text: &[u8; 12]) -> Vec<u8> {
        let mut p = vec![kind, track, seq, block_flags];
        p.extend_from_slice(text);
        let mut crc: u16 = 0;
        for &byte in &p {
            crc ^= (byte as u16) << 8;
            for _ in 0..8 {
                crc = if crc & 0x8000 != 0 {
                    (crc << 1) ^ 0x1021
                } else {
                    crc << 1
                };
            }
        }
        p.extend_from_slice(&(!crc).to_be_bytes());
        p
    }

    fn raw_text(packs: &[Vec<u8>]) -> Vec<u8> {
        let mut raw = vec![0u8, 0, 0, 0];
        for p in packs {
            raw.extend_from_slice(p);
        }
        let len = (raw.len() - 2) as u16;
        raw[0..2].copy_from_slice(&len.to_be_bytes());
        raw
    }

    #[test]
    fn cdtext_titles_split_across_packs_and_tab_repeat() {
        // 标题：盘 "Album" + 轨 1 "One" + 轨 2 "Second Song"；表演者：盘 "Band"，轨 1/2 TAB。
        let titles: &[u8] = b"Album\0One\0Second Song\0";
        let mut packs = Vec::new();
        let mut chunks = titles.chunks(12).peekable();
        let mut seq = 0u8;
        let mut track = 0u8;
        while let Some(c) = chunks.next() {
            let mut t = [0u8; 12];
            t[..c.len()].copy_from_slice(c);
            packs.push(pack(cdtext_field::TITLE, track, seq, 0, &t));
            seq += 1;
            track = 1; // 第二包从轨 1 开始（粗略，解析只看第一包的轨号）
        }
        let mut perf = [0u8; 12];
        perf[..9].copy_from_slice(b"Band\0\t\0\t\0");
        packs.push(pack(cdtext_field::PERFORMER, 0, seq, 0, &perf));
        // 第 1 块（另一种语言）不取。
        packs.push(pack(
            cdtext_field::TITLE,
            0,
            seq + 1,
            0x10,
            b"Other\0\0\0\0\0\0\0",
        ));
        let entries = parse_cdtext(&raw_text(&packs));
        let get = |track: u8, field: u8| {
            entries
                .iter()
                .find(|e| e.track == track && e.field == field)
                .map(|e| e.value.clone())
        };
        assert_eq!(get(0, cdtext_field::TITLE).as_deref(), Some("Album"));
        assert_eq!(get(1, cdtext_field::TITLE).as_deref(), Some("One"));
        assert_eq!(get(2, cdtext_field::TITLE).as_deref(), Some("Second Song"));
        assert_eq!(get(0, cdtext_field::PERFORMER).as_deref(), Some("Band"));
        assert_eq!(get(2, cdtext_field::PERFORMER).as_deref(), Some("Band"));
        assert!(entries.iter().all(|e| e.value != "Other"));
    }

    #[test]
    fn cdtext_ms_jis() {
        let (sjis, _, _) = encoding_rs::SHIFT_JIS.encode("夜");
        let mut t = [0u8; 12];
        t[..sjis.len()].copy_from_slice(&sjis);
        let packs = vec![
            pack(cdtext_field::TITLE, 0, 0, 0x80, &t),
            pack(
                cdtext_field::SIZE_INFO,
                0,
                1,
                0,
                &[0x80, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            ),
        ];
        let entries = parse_cdtext(&raw_text(&packs));
        assert_eq!(entries[0].value, "夜");
    }

    /// 本机光驱实测（`FUSHI_TEST_CD_DRIVE=E: cargo test -- --ignored --nocapture`）。
    #[test]
    #[ignore]
    fn read_local_drive() {
        let drive = std::env::var("FUSHI_TEST_CD_DRIVE").expect("FUSHI_TEST_CD_DRIVE");
        match device::read(&drive) {
            Ok((toc, text)) => {
                let info = info_from_raw(&toc, &text).expect("valid TOC");
                println!(
                    "toc={:?} id={:?} text={:?}",
                    info.toc, info.disc_id, info.cdtext
                );
            }
            Err(e) => panic!("{e:?}"),
        }
    }

    #[test]
    fn encode_info_layout() {
        let info = info_from_raw(&raw_toc(1, 1, &[(1, false, 0)], 1000), &[]).unwrap();
        let bytes = encode_info(&info);
        assert_eq!(&bytes[0..4], &1u32.to_le_bytes());
        assert_eq!(bytes[4], 1);
        assert_eq!(bytes[5], 1);
        assert_eq!(&bytes[6..10], &1000u32.to_le_bytes());
    }
}

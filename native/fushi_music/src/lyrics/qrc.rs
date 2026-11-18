//! QQ 音乐 QRC 专属的两件事（明文 QRC 本身的逐字解析在 [super::syllabic]）：
//!
//! 1. **加密 QRC 解密**。三种载体，解密后都是 zlib 压缩的明文 / XML 包装 QRC：
//!    - 本地缓存 `.qrc`（`QQMusicCache/QQMusicLyricNew/*.qrc`）：整个文件先按 QMC1 的 128 字节表
//!      循环异或（偏移从文件头算），异或后头 11 字节是明文 `[offset:0]\n`，丢掉；
//!    - 接口返回的十六进制串（`GetPlayLyricInfo` 带 `qrc=1` 时 `lyric` / `trans` / `roma` 字段，
//!      在线音源插件可能原样交 `format: qrc`）；
//!    - 已去掉 QMC1 层的裸密文。
//!
//!    分组密码是 QQ 音乐客户端 `QQMusicCommon.dll` 里的 DES：照搬了 Brad Conte 的
//!    crypto-algorithms `des.c`，连同它与 FIPS 46-3 不一致的两处 S 盒取值（S2 第 2 行第 8 个是
//!    15 而不是 14，S4 第 4 行第 6 个是 10 而不是 1）一起，所以标准 DES 库解不开。本模块逐行移植
//!    那份 C 实现（公开实现见 `wangqr/QQMusicDES`、`jixunmoe-go/qrc`），三重 DES-EDE 解密、ECB、
//!    密钥 `!@#)(*$%123ZXC!@!@#)(NHL`。测试向量里有一块取自真实接口返回的密文。
//!
//! 2. **`[kana:…]` 假名注音轨 → 音节 ruby**。日语歌的 QRC 带一个元数据标签，按正文里汉字出现的
//!    顺序给每一段汉字一个读音：`[kana:1よる1か2あす…]` = 第 1 个汉字读「よる」、下一个读「か」、
//!    再下两个合起来读「あす」。逐字版本的读音里夹着 `(起,长)` 逐拍时间，ruby 不用，丢掉。
//!    这是**来源文件自带的注音**（QQ 音乐提供），照原样显示；Fushi 自己不推断任何读音
//!    （feature-blacklist：禁止自动注音）。注音段数与正文汉字数对不上时整份不挂，宁缺不错位。

use super::model::*;

/// 本地缓存 `.qrc` 的文件头（QMC1 异或后的明文是 `[offset:0]\n`）。
const LOCAL_MAGIC: [u8; 11] = [
    0x98, 0x25, 0xB0, 0xAC, 0xE3, 0x02, 0x83, 0x68, 0xE8, 0xFC, 0x6C,
];

const QRC_KEY: &[u8; 24] = b"!@#)(*$%123ZXC!@!@#)(NHL";

const QMC1_KEY: [u8; 128] = [
    0xc3, 0x4a, 0xd6, 0xca, 0x90, 0x67, 0xf7, 0x52, 0xd8, 0xa1, 0x66, 0x62, 0x9f, 0x5b, 0x09, 0x00,
    0xc3, 0x5e, 0x95, 0x23, 0x9f, 0x13, 0x11, 0x7e, 0xd8, 0x92, 0x3f, 0xbc, 0x90, 0xbb, 0x74, 0x0e,
    0xc3, 0x47, 0x74, 0x3d, 0x90, 0xaa, 0x3f, 0x51, 0xd8, 0xf4, 0x11, 0x84, 0x9f, 0xde, 0x95, 0x1d,
    0xc3, 0xc6, 0x09, 0xd5, 0x9f, 0xfa, 0x66, 0xf9, 0xd8, 0xf0, 0xf7, 0xa0, 0x90, 0xa1, 0xd6, 0xf3,
    0xc3, 0xf3, 0xd6, 0xa1, 0x90, 0xa0, 0xf7, 0xf0, 0xd8, 0xf9, 0x66, 0xfa, 0x9f, 0xd5, 0x09, 0xc6,
    0xc3, 0x1d, 0x95, 0xde, 0x9f, 0x84, 0x11, 0xf4, 0xd8, 0x51, 0x3f, 0xaa, 0x90, 0x3d, 0x74, 0x47,
    0xc3, 0x0e, 0x74, 0xbb, 0x90, 0xbc, 0x3f, 0x92, 0xd8, 0x7e, 0x11, 0x13, 0x9f, 0x23, 0x95, 0x5e,
    0xc3, 0x00, 0x09, 0x5b, 0x9f, 0x62, 0x66, 0xa1, 0xd8, 0x52, 0xf7, 0x67, 0x90, 0xca, 0xd6, 0x4a,
];

fn qmc1_mask(offset: usize) -> u8 {
    if offset > 0x7FFF {
        QMC1_KEY[(offset % 0x7FFF) & 0x7F]
    } else {
        QMC1_KEY[offset & 0x7F]
    }
}

fn qmc1_xor(data: &mut [u8]) {
    for (i, b) in data.iter_mut().enumerate() {
        *b ^= qmc1_mask(i);
    }
}

/// 加密 QRC 的载体。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cipher {
    /// 本地缓存文件（QMC1 异或 + 11 字节头 + 3DES + zlib）。
    Local,
    /// 十六进制串（3DES + zlib）。
    Hex,
    /// 裸密文（3DES + zlib）。
    Raw,
}

/// 判断字节是不是加密 QRC。本地缓存靠文件头认，不看提示；十六进制串与裸密文只在提示是
/// `qrc` 时才认（别的格式里一串十六进制可能就是正文）。明文 / XML 包装 QRC 返回 None。
pub fn sniff_encrypted(bytes: &[u8], qrc_hint: bool) -> Option<Cipher> {
    if bytes.starts_with(&LOCAL_MAGIC) {
        return Some(Cipher::Local);
    }
    if !qrc_hint {
        return None;
    }
    let trimmed = bytes.trim_ascii();
    if !trimmed.is_empty() && trimmed.iter().all(u8::is_ascii_hexdigit) {
        return Some(Cipher::Hex);
    }
    let textual = bytes.contains(&b'[') || contains(bytes, b"LyricContent");
    (!textual).then_some(Cipher::Raw)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// 解密成明文 QRC 字节（UTF-8）。密文长度不是 8 的倍数、zlib 解不开都返回 None。
pub fn decrypt(bytes: &[u8], cipher: Cipher) -> Option<Vec<u8>> {
    let mut data = match cipher {
        Cipher::Local => {
            let mut d = bytes.to_vec();
            qmc1_xor(&mut d);
            d.split_off(LOCAL_MAGIC.len())
        }
        Cipher::Hex => data_encoding::HEXLOWER_PERMISSIVE
            .decode(bytes.trim_ascii())
            .ok()?,
        Cipher::Raw => bytes.to_vec(),
    };
    if data.is_empty() || data.len() % 8 != 0 {
        return None;
    }
    let des = TripleDes::new(QRC_KEY, Mode::Decrypt);
    for block in data.chunks_exact_mut(8) {
        des.crypt(block);
    }
    super::inflate_bounded(&data, super::MAX_INFLATED_BYTES)
}

/// 测试 / 往返用：把明文 QRC 加密成 [Cipher::Raw] 密文（zlib → 补零到 8 的倍数 → 3DES）。
pub fn encrypt_raw(plain: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(plain).unwrap();
    let mut data = z.finish().unwrap();
    data.resize(data.len().div_ceil(8) * 8, 0);
    let des = TripleDes::new(QRC_KEY, Mode::Encrypt);
    for block in data.chunks_exact_mut(8) {
        des.crypt(block);
    }
    data
}

/// 测试 / 往返用：接口形态的大写十六进制串。
pub fn encrypt_hex(plain: &[u8]) -> String {
    data_encoding::HEXUPPER.encode(&encrypt_raw(plain))
}

/// 测试 / 往返用：本地缓存文件形态。
pub fn encrypt_local(plain: &[u8]) -> Vec<u8> {
    let mut out = b"[offset:0]\n".to_vec();
    out.extend(encrypt_raw(plain));
    qmc1_xor(&mut out);
    out
}

// ───────────────────────── QQ 音乐的 DES（Brad Conte des.c 逐行移植） ─────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Encrypt,
    Decrypt,
}

type Schedule = [[u8; 6]; 16];

const SBOX: [[u8; 64]; 8] = [
    [
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12,
        11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9,
        1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
    ],
    [
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1,
        10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15,
        4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
    ],
    [
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5,
        14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6,
        9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
    ],
    [
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2,
        12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10,
        10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
    ],
    [
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15,
        10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14,
        2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
    ],
    [
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13,
        14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5,
        15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
    ],
    [
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5,
        12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4,
        10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
    ],
    [
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6,
        11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10,
        8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    ],
];

/// 初始置换：`state[0]` / `state[1]` 的第 31-i 位取输入的第 IP0[i] / IP1[i] 位。
const IP0: [usize; 32] = [
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63,
    55, 47, 39, 31, 23, 15, 7,
];
const IP1: [usize; 32] = [
    56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62,
    54, 46, 38, 30, 22, 14, 6,
];
const PBOX: [u32; 32] = [
    15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12,
    29, 5, 21, 10, 3, 24,
];
const KEY_SHIFT: [u32; 16] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
const KEY_PERM_C: [usize; 28] = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59,
    51, 43, 35,
];
const KEY_PERM_D: [usize; 28] = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4,
    27, 19, 11, 3,
];
const KEY_COMPRESSION: [u32; 48] = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51,
    30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
];

/// `BITNUM`：按 des.c 的字节序取第 b 位（每 4 字节一组倒序），放到第 c 位。
fn bitnum(a: &[u8], b: usize, c: u32) -> u32 {
    (((a[b / 32 * 4 + 3 - b % 32 / 8] >> (7 - (b % 8))) & 1) as u32) << c
}

/// `BITNUMINTR`：取 a 从高位数第 b 位，放到第 c 位。
fn bitr(a: u32, b: u32, c: u32) -> u32 {
    ((a >> (31 - b)) & 1) << c
}

/// `BITNUMINTL`：取 a 从高位数第 b 位，放到从高位数第 c 位。
fn bitl(a: u32, b: u32, c: u32) -> u32 {
    ((a << b) & 0x8000_0000) >> c
}

/// `SBOXBIT`：首末两位作行号的 6 位块 → 前两位作行号。
fn sbox_bit(a: u8) -> usize {
    ((a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4)) as usize
}

fn initial_permutation(input: &[u8]) -> [u32; 2] {
    let mut s = [0u32; 2];
    for i in 0..32 {
        s[0] |= bitnum(input, IP0[i], 31 - i as u32);
        s[1] |= bitnum(input, IP1[i], 31 - i as u32);
    }
    s
}

fn inverse_permutation(s: [u32; 2], out: &mut [u8]) {
    // 输出字节 3,2,1,0,7,6,5,4 依次取状态的第 7..0 列。
    const ORDER: [usize; 8] = [3, 2, 1, 0, 7, 6, 5, 4];
    for (k, &idx) in ORDER.iter().enumerate() {
        let base = 7 - k as u32;
        let mut v = 0u32;
        for j in 0..4u32 {
            let b = base + 8 * j;
            v |= bitr(s[1], b, 7 - 2 * j) | bitr(s[0], b, 6 - 2 * j);
        }
        out[idx] = v as u8;
    }
}

fn feistel(state: u32, key: &[u8; 6]) -> u32 {
    let t1 = bitl(state, 31, 0)
        | ((state & 0xf000_0000) >> 1)
        | bitl(state, 4, 5)
        | bitl(state, 3, 6)
        | ((state & 0x0f00_0000) >> 3)
        | bitl(state, 8, 11)
        | bitl(state, 7, 12)
        | ((state & 0x00f0_0000) >> 5)
        | bitl(state, 12, 17)
        | bitl(state, 11, 18)
        | ((state & 0x000f_0000) >> 7)
        | bitl(state, 16, 23);
    let t2 = bitl(state, 15, 0)
        | ((state & 0x0000_f000) << 15)
        | bitl(state, 20, 5)
        | bitl(state, 19, 6)
        | ((state & 0x0000_0f00) << 13)
        | bitl(state, 24, 11)
        | bitl(state, 23, 12)
        | ((state & 0x0000_00f0) << 11)
        | bitl(state, 28, 17)
        | bitl(state, 27, 18)
        | ((state & 0x0000_000f) << 9)
        | bitl(state, 0, 23);
    let mut l = [
        (t1 >> 24) as u8,
        (t1 >> 16) as u8,
        (t1 >> 8) as u8,
        (t2 >> 24) as u8,
        (t2 >> 16) as u8,
        (t2 >> 8) as u8,
    ];
    for (b, k) in l.iter_mut().zip(key) {
        *b ^= k;
    }
    let s = (SBOX[0][sbox_bit(l[0] >> 2)] as u32) << 28
        | (SBOX[1][sbox_bit(((l[0] & 0x03) << 4) | (l[1] >> 4))] as u32) << 24
        | (SBOX[2][sbox_bit(((l[1] & 0x0f) << 2) | (l[2] >> 6))] as u32) << 20
        | (SBOX[3][sbox_bit(l[2] & 0x3f)] as u32) << 16
        | (SBOX[4][sbox_bit(l[3] >> 2)] as u32) << 12
        | (SBOX[5][sbox_bit(((l[3] & 0x03) << 4) | (l[4] >> 4))] as u32) << 8
        | (SBOX[6][sbox_bit(((l[4] & 0x0f) << 2) | (l[5] >> 6))] as u32) << 4
        | SBOX[7][sbox_bit(l[5] & 0x3f)] as u32;
    PBOX.iter()
        .enumerate()
        .fold(0u32, |acc, (i, &b)| acc | bitl(s, b, i as u32))
}

fn key_schedule(key: &[u8], mode: Mode) -> Schedule {
    let mut c = 0u32;
    let mut d = 0u32;
    for i in 0..28 {
        c |= bitnum(key, KEY_PERM_C[i], 31 - i as u32);
        d |= bitnum(key, KEY_PERM_D[i], 31 - i as u32);
    }
    let mut sched: Schedule = [[0; 6]; 16];
    for (i, &sh) in KEY_SHIFT.iter().enumerate() {
        c = ((c << sh) | (c >> (28 - sh))) & 0xffff_fff0;
        d = ((d << sh) | (d >> (28 - sh))) & 0xffff_fff0;
        let to = if mode == Mode::Decrypt { 15 - i } else { i };
        let k = &mut sched[to];
        *k = [0; 6];
        for (j, &bit) in KEY_COMPRESSION.iter().enumerate() {
            let v = if j < 24 {
                bitr(c, bit, 7 - (j % 8) as u32)
            } else {
                bitr(d, bit - 27, 7 - (j % 8) as u32)
            };
            k[j / 8] |= v as u8;
        }
    }
    sched
}

fn des_crypt(block: &mut [u8], key: &Schedule) {
    let mut s = initial_permutation(block);
    for k in &key[..15] {
        let t = s[1];
        s[1] = feistel(s[1], k) ^ s[0];
        s[0] = t;
    }
    s[0] ^= feistel(s[1], &key[15]);
    inverse_permutation(s, block);
}

struct TripleDes([Schedule; 3]);

impl TripleDes {
    /// des.c 的 `three_des_key_setup`：加密 = K1 加、K2 解、K3 加；解密倒过来。
    fn new(key: &[u8; 24], mode: Mode) -> Self {
        let inv = match mode {
            Mode::Encrypt => Mode::Decrypt,
            Mode::Decrypt => Mode::Encrypt,
        };
        let (k1, k2, k3) = (&key[0..8], &key[8..16], &key[16..24]);
        TripleDes(match mode {
            Mode::Encrypt => [
                key_schedule(k1, mode),
                key_schedule(k2, inv),
                key_schedule(k3, mode),
            ],
            Mode::Decrypt => [
                key_schedule(k3, mode),
                key_schedule(k2, inv),
                key_schedule(k1, mode),
            ],
        })
    }

    fn crypt(&self, block: &mut [u8]) {
        for s in &self.0 {
            des_crypt(block, s);
        }
    }
}

// ───────────────────────────── `[kana:…]` 注音轨 ─────────────────────────────

/// 注音轨按「汉字」计数时一定算的字：CJK 统一表意文字（基本区与扩展 A 起各扩展区，到
/// Unicode 17 的扩展 J U+323B0–3347F 为止）、兼容表意文字（含兼容补充区 U+2F800–2FA1F，
/// 落在扩展区段内）与叠字符 `々`。
pub fn is_kanji(c: char) -> bool {
    matches!(
        c as u32,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x3347F
    ) || c == '々'
}

/// 归不归「汉字」随口径而变的字：`〇`（Script=Han、Ideographic）与 `〆`（Ideographic，但
/// Script=Common）。来源（QQ 音乐）按哪种口径数没有公开约定，[apply_kana] 对每种取舍都做
/// 完整对齐校验，只采用唯一对得上的那种。
const AMBIGUOUS_KANJI: [char; 2] = ['〇', '〆'];

/// `[kana:…]` 正文 → (覆盖的汉字数, 读音)。读音里的 `(起,长)` 逐拍时间去掉。格式不对返回 None。
pub fn parse_kana(tag: &str) -> Option<Vec<(usize, String)>> {
    let cleaned = strip_time_groups(tag);
    let mut out = Vec::new();
    let mut it = cleaned.trim().chars().peekable();
    while it.peek().is_some() {
        let mut n = 0usize;
        let mut digits = 0;
        while let Some(d) = it.peek().and_then(|c| c.to_digit(10)) {
            n = n.checked_mul(10)?.checked_add(d as usize)?;
            digits += 1;
            it.next();
        }
        if digits == 0 || n == 0 {
            return None;
        }
        let mut reading = String::new();
        while let Some(&c) = it.peek().filter(|c| !c.is_ascii_digit()) {
            reading.push(c);
            it.next();
        }
        let reading = reading.trim();
        if reading.is_empty() {
            return None;
        }
        out.push((n, reading.to_owned()));
    }
    (!out.is_empty()).then_some(out)
}

/// 去掉 `(数字,数字)` 时间组；别的括号原样保留。
fn strip_time_groups(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(o) = rest.find('(') {
        out.push_str(&rest[..o]);
        let after = &rest[o + 1..];
        match after.find(')') {
            Some(c)
                if after[..c].contains(',')
                    && after[..c]
                        .chars()
                        .all(|ch| ch.is_ascii_digit() || ch == ',') =>
            {
                rest = &after[c + 1..];
            }
            _ => {
                out.push('(');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// 一段注音：行内字符区间 `[start, end)` 与读音。
type Span = (usize, usize, String);

/// 把注音轨挂到音节 ruby 上：汉字段跨音节的并成一个音节，音节里只有一部分是注音段的按字数
/// 拆开（时间按字数平分）。[AMBIGUOUS_KANJI] 里每个字算不算汉字的每种取舍各做一次完整
/// 对齐；没有一种对得上（总数不等、一段跨了非汉字或跨行），或有两种都对得上但挂法不同时，
/// 什么都不改，返回 false。需在 [Timeline::finalize] 之前调用。
pub fn apply_kana(t: &mut Timeline, tag: &str) -> bool {
    let Some(groups) = parse_kana(tag) else {
        return false;
    };
    let mut chosen: Option<Vec<Vec<Span>>> = None;
    for mask in 0u32..1 << AMBIGUOUS_KANJI.len() {
        let counts = |c: char| -> bool {
            is_kanji(c)
                || AMBIGUOUS_KANJI
                    .iter()
                    .enumerate()
                    .any(|(i, &a)| a == c && mask >> i & 1 == 1)
        };
        let Some(plan) = plan_kana(t, &groups, counts) else {
            continue;
        };
        match &chosen {
            None => chosen = Some(plan),
            Some(prev) if *prev == plan => {}
            // 两种口径都对得上却挂法不同：分不出哪种是来源的口径，宁缺不错位。
            Some(_) => return false,
        }
    }
    let Some(per_line) = chosen else {
        return false;
    };
    for (line, spans) in t.lines.iter_mut().zip(per_line) {
        if !spans.is_empty() {
            attach_spans(line, &spans);
        }
    }
    true
}

/// 按 `counts` 的汉字口径只读地算出每行的注音段；总数不等、一段跨了非汉字或跨行返回 None。
fn plan_kana(
    t: &Timeline,
    groups: &[(usize, String)],
    counts: impl Fn(char) -> bool,
) -> Option<Vec<Vec<Span>>> {
    let total: usize = groups.iter().map(|g| g.0).sum();
    let kanji: usize = t
        .lines
        .iter()
        .flat_map(|l| l.syllables.iter())
        .map(|s| s.text.chars().filter(|&c| counts(c)).count())
        .sum();
    if total != kanji {
        return None;
    }
    let mut groups = groups.iter();
    let mut per_line: Vec<Vec<Span>> = Vec::with_capacity(t.lines.len());
    for line in &t.lines {
        let chars: Vec<char> = line.syllables.iter().flat_map(|s| s.text.chars()).collect();
        let mut spans = Vec::new();
        let mut i = 0;
        while i < chars.len() {
            if !counts(chars[i]) {
                i += 1;
                continue;
            }
            let (n, reading) = groups.next()?;
            let end = i + n;
            if end > chars.len() || !chars[i..end].iter().all(|&c| counts(c)) {
                return None;
            }
            spans.push((i, end, reading.clone()));
            i = end;
        }
        per_line.push(spans);
    }
    Some(per_line)
}

fn attach_spans(line: &mut Line, spans: &[Span]) {
    let cuts: std::collections::BTreeSet<usize> =
        spans.iter().flat_map(|&(s, e, _)| [s, e]).collect();
    // 1. 在注音段边界处切音节。
    let mut pieces: Vec<(Syllable, usize)> = Vec::new();
    let mut offset = 0usize;
    for syl in std::mem::take(&mut line.syllables) {
        let chars: Vec<char> = syl.text.chars().collect();
        let len = chars.len();
        let inner: Vec<usize> = cuts
            .range(offset + 1..offset + len.max(1))
            .map(|c| c - offset)
            .collect();
        if inner.is_empty() {
            pieces.push((syl, offset));
        } else {
            let dur = syl.end_ms - syl.start_ms;
            let mut bounds = vec![0];
            bounds.extend(inner);
            bounds.push(len);
            for w in bounds.windows(2) {
                let mut p = syl.clone();
                p.text = chars[w[0]..w[1]].iter().collect();
                p.start_ms = syl.start_ms + dur * w[0] as i64 / len as i64;
                p.end_ms = syl.start_ms + dur * w[1] as i64 / len as i64;
                pieces.push((p, offset + w[0]));
            }
        }
        offset += len;
    }
    // 2. 同一注音段的片段并成一个音节，挂 ruby。
    let mut out: Vec<Syllable> = Vec::with_capacity(pieces.len());
    let mut si = 0;
    for (p, at) in pieces {
        while si < spans.len() && spans[si].1 <= at {
            si += 1;
        }
        match spans.get(si) {
            Some((start, _, reading)) if *start == at => {
                let mut p = p;
                p.ruby = Some(reading.clone());
                out.push(p);
            }
            Some((start, _, _)) if *start < at => {
                let last = out.last_mut().expect("span head pushed first");
                last.text.push_str(&p.text);
                last.end_ms = last.end_ms.max(p.end_ms);
            }
            _ => out.push(p),
        }
    }
    line.syllables = out;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rubies(l: &Line) -> Vec<(String, Option<String>, i64, i64)> {
        l.syllables
            .iter()
            .map(|s| (s.text.clone(), s.ruby.clone(), s.start_ms, s.end_ms))
            .collect()
    }

    #[test]
    fn des_matches_reference_vector() {
        // jixunmoe-go/qrc 的 des_impl_test.go：密钥 "TEST!KEY"，加密方向。
        let mut block = [0xFD, 0x0E, 0x64, 0x06, 0x65, 0xBE, 0x74, 0x13];
        des_crypt(&mut block, &key_schedule(b"TEST!KEY", Mode::Encrypt));
        assert_eq!(block, [1, 2, 3, 4, 5, 6, 7, 8]);
        des_crypt(&mut block, &key_schedule(b"TEST!KEY", Mode::Decrypt));
        assert_eq!(block, [0xFD, 0x0E, 0x64, 0x06, 0x65, 0xBE, 0x74, 0x13]);
    }

    #[test]
    fn triple_des_decrypts_a_real_qq_music_block() {
        // QQ 音乐 GetPlayLyricInfo（qrc=1）真实返回的 lyric 字段第一块：解出以 zlib 头 78 9C
        // 开头的压缩流（整份解开是带 `[kana:]` 的 XML 包装 QRC，正文不入库）。
        let mut block = data_encoding::HEXUPPER.decode(b"859205DD70724242").unwrap();
        TripleDes::new(QRC_KEY, Mode::Decrypt).crypt(&mut block);
        assert_eq!(block, [0x78, 0x9C, 0x6D, 0x5B, 0x5B, 0x8F, 0x96, 0xD7]);
    }

    #[test]
    fn all_three_carriers_round_trip() {
        let plain = "[1000,500]夜(1000,500)".as_bytes();
        let hex = encrypt_hex(plain);
        assert_eq!(sniff_encrypted(hex.as_bytes(), true), Some(Cipher::Hex));
        assert_eq!(sniff_encrypted(hex.as_bytes(), false), None);
        assert_eq!(decrypt(hex.as_bytes(), Cipher::Hex).unwrap(), plain);

        let local = encrypt_local(plain);
        assert!(local.starts_with(&LOCAL_MAGIC));
        assert_eq!(sniff_encrypted(&local, false), Some(Cipher::Local));
        assert_eq!(decrypt(&local, Cipher::Local).unwrap(), plain);

        let raw = encrypt_raw(plain);
        if !raw.contains(&b'[') {
            assert_eq!(sniff_encrypted(&raw, true), Some(Cipher::Raw));
        }
        assert_eq!(decrypt(&raw, Cipher::Raw).unwrap(), plain);

        assert_eq!(sniff_encrypted(plain, true), None);
        assert_eq!(decrypt(b"0123456789ABCDEF", Cipher::Hex), None);
        assert_eq!(decrypt(b"short", Cipher::Raw), None);
    }

    #[test]
    fn qrc_decompression_bomb_is_rejected() {
        // 三种载体都走同一个有上限的解压：超过明文上限一律 None。
        let plain = vec![b'['; crate::lyrics::MAX_INFLATED_BYTES + 1];
        let raw = encrypt_raw(&plain);
        assert!(raw.len() < 64 * 1024);
        assert_eq!(decrypt(&raw, Cipher::Raw), None);
        assert_eq!(decrypt(encrypt_hex(&plain).as_bytes(), Cipher::Hex), None);
        assert_eq!(decrypt(&encrypt_local(&plain), Cipher::Local), None);
        assert!(crate::lyrics::parse(encrypt_hex(&plain).as_bytes(), "qrc", None).is_err());
        let at_limit = vec![b'['; crate::lyrics::MAX_INFLATED_BYTES];
        assert_eq!(
            decrypt(&encrypt_raw(&at_limit), Cipher::Raw).map(|v| v.len()),
            Some(crate::lyrics::MAX_INFLATED_BYTES)
        );
    }

    #[test]
    fn kana_tag_parses_counts_and_strips_mora_times() {
        assert_eq!(
            parse_kana("1よる1ふ(9201,192)た(9393,258)2あす").unwrap(),
            vec![
                (1, "よる".to_owned()),
                (1, "ふた".to_owned()),
                (2, "あす".to_owned()),
            ]
        );
        assert_eq!(parse_kana(""), None);
        assert_eq!(parse_kana("よる"), None);
        assert_eq!(parse_kana("1"), None);
    }

    fn qrc_line(syls: &[(&str, i64, i64)]) -> Line {
        Line {
            start_ms: syls[0].1,
            end_ms: syls.last().map(|s| s.2).unwrap(),
            syllables: syls
                .iter()
                .map(|&(t, s, e)| Syllable::new(t, s, e))
                .collect(),
            ..Line::default()
        }
    }

    #[test]
    fn kana_attaches_merges_and_splits() {
        let mut t = Timeline::new("qrc", TimingQuality::Syllable);
        // 明日：两个音节合成一段；「夜に」一个音节拆成「夜」+「に」。
        t.lines.push(qrc_line(&[
            ("明", 0, 100),
            ("日", 100, 200),
            ("の", 200, 300),
        ]));
        t.lines
            .push(qrc_line(&[("夜に", 1000, 1200), ("駆", 1200, 1300)]));
        assert!(apply_kana(&mut t, "2あす1よる1か"));
        assert_eq!(
            rubies(&t.lines[0]),
            vec![
                ("明日".into(), Some("あす".into()), 0, 200),
                ("の".into(), None, 200, 300),
            ]
        );
        assert_eq!(
            rubies(&t.lines[1]),
            vec![
                ("夜".into(), Some("よる".into()), 1000, 1100),
                ("に".into(), None, 1100, 1200),
                ("駆".into(), Some("か".into()), 1200, 1300),
            ]
        );
    }

    #[test]
    fn mismatched_kana_track_changes_nothing() {
        let mut t = Timeline::new("qrc", TimingQuality::Syllable);
        t.lines.push(qrc_line(&[("夜", 0, 100), ("に", 100, 200)]));
        t.lines.push(qrc_line(&[("駆", 300, 400)]));
        let before = t.lines.clone();
        // 总数不等。
        assert!(!apply_kana(&mut t, "1よる"));
        // 总数相等但一段跨了非汉字（夜に）。
        assert!(!apply_kana(&mut t, "2よる"));
        // 一段跨行。
        let mut t2 = Timeline::new("qrc", TimingQuality::Syllable);
        t2.lines.push(qrc_line(&[("夜", 0, 100)]));
        t2.lines.push(qrc_line(&[("駆", 300, 400)]));
        let before2 = t2.lines.clone();
        assert!(!apply_kana(&mut t2, "2よるか"));
        assert_eq!(t.lines, before);
        assert_eq!(t2.lines, before2);
    }

    fn texts_and_rubies(t: &Timeline) -> Vec<Vec<(String, Option<String>)>> {
        t.lines
            .iter()
            .map(|l| {
                l.syllables
                    .iter()
                    .map(|s| (s.text.clone(), s.ruby.clone()))
                    .collect()
            })
            .collect()
    }

    fn one_line(syls: &[(&str, i64, i64)]) -> Timeline {
        let mut t = Timeline::new("qrc", TimingQuality::Syllable);
        t.lines.push(qrc_line(syls));
        t
    }

    #[test]
    fn kana_track_counting_ideographic_zero_attaches() {
        // 来源把 〇 数进汉字：二〇二〇 一段读音。旧口径不认 〇，总数 3 ≠ 5，整首不挂。
        let mut t = one_line(&[("二〇二〇", 0, 400), ("年", 400, 500), ("に", 500, 600)]);
        assert!(apply_kana(&mut t, "4にせんにじゅう1ねん"));
        assert_eq!(
            texts_and_rubies(&t)[0],
            vec![
                ("二〇二〇".into(), Some("にせんにじゅう".into())),
                ("年".into(), Some("ねん".into())),
                ("に".into(), None),
            ]
        );
    }

    #[test]
    fn kana_track_not_counting_shime_mark_attaches() {
        // 来源不把 〆 数进汉字。旧口径把 〆 算汉字，总数 1 ≠ 2，整首不挂。
        let mut t = one_line(&[("〆", 0, 100), ("の", 100, 200), ("夜", 200, 300)]);
        assert!(apply_kana(&mut t, "1よる"));
        assert_eq!(
            texts_and_rubies(&t)[0],
            vec![
                ("〆".into(), None),
                ("の".into(), None),
                ("夜".into(), Some("よる".into())),
            ]
        );
        // 反过来来源数了 〆 也照挂。
        let mut t = one_line(&[("〆切", 0, 200), ("の", 200, 300)]);
        assert!(apply_kana(&mut t, "2しめきり"));
        assert_eq!(
            texts_and_rubies(&t)[0][0],
            ("〆切".into(), Some("しめきり".into()))
        );
    }

    #[test]
    fn kana_track_counts_extension_h_ideographs() {
        // U+31350（CJK 统一表意文字扩展 H）是汉字；旧口径只到 U+3134F，总数 1 ≠ 2。
        // 兼容补充区（U+2F800–2FA1F）一直在范围内，一并钉住。
        assert!(is_kanji('\u{2F800}'));
        // 扩展 J（Unicode 17，U+323B0–3347F）紧接扩展 H，同样一定算汉字。
        assert!(is_kanji('\u{323B0}'));
        assert!(is_kanji('\u{33479}'));
        let mut t = one_line(&[("\u{31350}", 0, 100), ("夜", 100, 200)]);
        assert!(apply_kana(&mut t, "1あ1よる"));
        assert_eq!(
            texts_and_rubies(&t)[0],
            vec![
                ("\u{31350}".into(), Some("あ".into())),
                ("夜".into(), Some("よる".into())),
            ]
        );
    }

    #[test]
    fn kana_track_ambiguous_between_conventions_changes_nothing() {
        // 「只数 〇」与「只数 〆」两种口径都对得上但挂法不同：分不出来源口径，不挂。
        let mut t = one_line(&[("〇", 0, 100), ("夜", 100, 200), ("〆", 200, 300)]);
        let before = t.lines.clone();
        assert!(!apply_kana(&mut t, "1あ1い"));
        assert_eq!(t.lines, before);
    }
}

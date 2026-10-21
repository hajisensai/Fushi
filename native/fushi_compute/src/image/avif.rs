//! AVIF（HEIF 容器 + AV1 帧）静态图解码：`ffc_image_decode` / `ffc_image_probe` 认出 AVIF 后走这里。
//!
//! 为什么不用 `image` crate 的 `avif-native`：它绑 dav1d（C 库 + meson / nasm），五端交叉编译要
//! 各配一套 C 工具链；`avif-parse` + `avif-decode` 则不支持 grid 拼图、不处理 `clap` / `irot` /
//! `imir`，而漫画 / 封面里的大图正是 grid 的主要来源。所以容器解析在本文件自己做，AV1 帧交给
//! `rav1d`（dav1d 的纯 Rust 移植，关掉 asm 特性），YUV → RGB 也在这里。rav1d 的调用套路参考
//! kornelski/avif-decode 3.0（BSD-3-Clause）的 `src/rav1d.rs`。
//!
//! 支持面：
//! - 主图 `av01` 或 `grid`（ISO/IEC 23008-12 §6.6.2.3，瓦片按 `dimg` 引用顺序、行主序铺）；
//! - `iloc` 构造方式 0（文件偏移）与 1（`idat` 偏移），多 extent 拼接；
//! - alpha 辅助图（`auxl` 引用 + `auxC` 为 alpha URN），本身也可以是 grid；`prem` 时反预乘；
//! - 变换性质按规范顺序 `clap` → `irot` → `imir` 应用。它们是 HEIF 的**必选显示变换**
//!   （不是 EXIF 那种可选元数据），浏览器 / WebView 一律应用，所以与 `orient` 参数无关、总是应用：
//!   否则 OCR 坐标会与阅读器里显示的页面对不上；
//! - 颜色：优先 `colr`（nclx）的矩阵系数与范围，否则取 AV1 序列头；8 / 10 / 12 位、4:0:0 /
//!   4:2:0 / 4:2:2 / 4:4:4；输出一律 8 位 RGB（有 alpha 时 RGBA）。色度上采样按中心采样位置做双线性（见 `upsample`）。
//!
//! rav1d 的默认 logger 会把码流解析错误打到 stderr（Rust API 的 `Settings` 不暴露 logger）；只在
//! 坏图上出现，GUI / 移动端 stderr 无人读，服务端终端里多几行，不另做处理。
//!
//! 动图（`avis` 图像序列）的逐帧解码在子模块 `sequence`（`ffc_image_avif_anim_*`）；本文件的
//! [decode] / [probe] 只看静态主图（动图的 `pitm` 通常就是首帧）。
//!
//! 不支持（返回 BAD_INPUT）：只有图像序列没有静态主图的动图（`avis` 无 `pitm`）、构造方式 2、
//! `iovl` 叠图、其它 `ipma` 标成必选而本解码器不认识的性质（按规范必须拒绝）。

use crate::status;
use std::mem::ManuallyDrop;
use std::panic::{catch_unwind, AssertUnwindSafe};

mod sequence;
pub(crate) use sequence::AvifAnimation;

type R<T> = Result<T, i32>;

/// 画布像素上限（与 grid 输出尺寸、单帧尺寸共用）：16384²，防恶意文件让我们分配几十 GB。
const MAX_PIXELS: u64 = 16384 * 16384;

/// grid 瓦片数上限：超过就当坏文件（正常编码器的瓦片数远低于此）。
const MAX_TILES: usize = 4096;

/// 文件以 `ftyp` 开头且品牌（主品牌或兼容品牌）含 `avif` / `avis`。
pub(crate) fn is_avif(data: &[u8]) -> bool {
    let Some(b) = read_box_header(data, 0) else {
        return false;
    };
    if &b.kind != b"ftyp" || b.end > data.len() || b.end - b.body < 8 {
        return false;
    }
    let body = &data[b.body..b.end];
    let mut brands = vec![&body[0..4]];
    brands.extend(body[8..].chunks_exact(4));
    brands.iter().any(|x| *x == b"avif" || *x == b"avis")
}

/// 显示尺寸（已应用 `clap` / `irot`），只解析容器、不解 AV1。
pub(crate) fn probe(data: &[u8]) -> R<(u32, u32)> {
    let file = parse(data)?;
    let primary = file.item(file.primary)?;
    let (w, h) = file.coded_size(primary)?;
    let (w, h) = match file.clap(primary.id) {
        Some(c) => (c.w, c.h),
        None => (w, h),
    };
    Ok(if file.rotation(primary.id) % 2 == 1 {
        (h, w)
    } else {
        (w, h)
    })
}

/// 解码成 8 位行紧排 RGB（3 通道）或 RGBA（4 通道），返回 `(像素, 宽, 高, 通道数)`。
pub(crate) fn decode(data: &[u8]) -> R<(Vec<u8>, u32, u32, u32)> {
    let file = parse(data)?;
    let primary = file.item(file.primary)?;
    let (color, alpha) = decode_guarded(|decoder| {
        let color = file.decode_item(data, primary, decoder, Plane::Color)?;
        let alpha = match file.alpha_for(primary.id) {
            Some(id) => Some(file.decode_item(data, file.item(id)?, decoder, Plane::Alpha)?),
            None => None,
        };
        Ok((color, alpha))
    })?;
    let (w, h) = (color.w, color.h);
    let mut img = Canvas {
        ch: if alpha.is_some() { 4 } else { 3 },
        w,
        h,
        px: Vec::new(),
    };
    img.px = match &alpha {
        Some(a) => {
            if a.w != w || a.h != h {
                return Err(status::BAD_INPUT);
            }
            let mut out = vec![0u8; w * h * 4];
            for i in 0..w * h {
                out[i * 4..i * 4 + 3].copy_from_slice(&color.px[i * 3..i * 3 + 3]);
                out[i * 4 + 3] = a.px[i];
            }
            if file.premultiplied(primary.id) {
                for p in out.chunks_exact_mut(4) {
                    let a = p[3] as u32;
                    for c in &mut p[..3] {
                        *c = if a == 0 {
                            0
                        } else {
                            ((*c as u32 * 255 + a / 2) / a).min(255) as u8
                        };
                    }
                }
            }
            out
        }
        None => color.px,
    };
    if let Some(c) = file.clap(primary.id) {
        img = img.crop(c.x, c.y, c.w as usize, c.h as usize);
    }
    for _ in 0..file.rotation(primary.id) {
        img = img.rotate_ccw();
    }
    // imir 的 axis 取 libavif（Chrome / Firefox 同源）的约定：0 = 上下翻，1 = 左右翻。
    // libavif 把 EXIF 方向 2（左右翻）写成 axis = 1，本仓样本即由它生成。
    match file.mirror(primary.id) {
        Some(0) => img.flip_vertical(),
        Some(_) => img.flip_horizontal(),
        None => {}
    }
    Ok((img.px, img.w as u32, img.h as u32, img.ch as u32))
}

// ---------------------------------------------------------------------------
// ISOBMFF 盒子
// ---------------------------------------------------------------------------

struct BoxHeader {
    kind: [u8; 4],
    /// 盒子正文起点（头之后）。
    body: usize,
    /// 盒子终点（不含），已夹到不超过输入长度由调用方检查。
    end: usize,
}

fn read_box_header(data: &[u8], at: usize) -> Option<BoxHeader> {
    let size = u32::from_be_bytes(data.get(at..at + 4)?.try_into().ok()?) as u64;
    let kind: [u8; 4] = data.get(at + 4..at + 8)?.try_into().ok()?;
    let (body, size) = match size {
        0 => (at + 8, (data.len() - at) as u64),
        1 => (
            at + 16,
            u64::from_be_bytes(data.get(at + 8..at + 16)?.try_into().ok()?),
        ),
        n => (at + 8, n),
    };
    let end = (at as u64).checked_add(size)?;
    if end > data.len() as u64 || (end as usize) < body {
        return None;
    }
    Some(BoxHeader {
        kind,
        body,
        end: end as usize,
    })
}

/// 依次遍历 `data[start..end]` 内的子盒子。
fn children(data: &[u8], start: usize, end: usize) -> R<Vec<BoxHeader>> {
    let mut out = Vec::new();
    let mut at = start;
    while at + 8 <= end {
        let b = read_box_header(&data[..end], at).ok_or(status::BAD_INPUT)?;
        at = b.end;
        out.push(b);
    }
    Ok(out)
}

/// 大端读取游标。越界一律 BAD_INPUT。
struct Cursor<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, at: 0 }
    }
    fn bytes(&mut self, n: usize) -> R<&'a [u8]> {
        let end = self.at.checked_add(n).ok_or(status::BAD_INPUT)?;
        let s = self.data.get(self.at..end).ok_or(status::BAD_INPUT)?;
        self.at = end;
        Ok(s)
    }
    fn u8(&mut self) -> R<u8> {
        Ok(self.bytes(1)?[0])
    }
    fn u16(&mut self) -> R<u16> {
        Ok(u16::from_be_bytes(self.bytes(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> R<u32> {
        Ok(u32::from_be_bytes(self.bytes(4)?.try_into().unwrap()))
    }
    /// 按字节数读无符号整数（0 / 4 / 8，`iloc` 的可变宽字段）。
    fn uint(&mut self, size: u8) -> R<u64> {
        Ok(match size {
            0 => 0,
            4 => self.u32()? as u64,
            8 => u64::from_be_bytes(self.bytes(8)?.try_into().unwrap()),
            _ => return Err(status::BAD_INPUT),
        })
    }
    /// FullBox 头：`(version, flags)`。
    fn full_box(&mut self) -> R<(u8, u32)> {
        let v = self.u32()?;
        Ok(((v >> 24) as u8, v & 0x00ff_ffff))
    }
    fn cstring(&mut self) -> R<&'a [u8]> {
        let rest = &self.data[self.at.min(self.data.len())..];
        let n = rest.iter().position(|&c| c == 0).ok_or(status::BAD_INPUT)?;
        self.at += n + 1;
        Ok(&rest[..n])
    }
}

// ---------------------------------------------------------------------------
// meta 盒子里的物件表
// ---------------------------------------------------------------------------

struct Extent {
    offset: u64,
    /// 0 = 到数据末尾。
    length: u64,
}

struct Item {
    id: u32,
    kind: [u8; 4],
    construction: u8,
    base_offset: u64,
    extents: Vec<Extent>,
}

enum Property {
    Ispe {
        w: u32,
        h: u32,
    },
    Irot(u8),
    Imir(u8),
    Clap([u32; 8]),
    /// nclx：`(matrix_coefficients, full_range)`。
    Colr(u16, bool),
    AuxAlpha,
    /// 解码不需要读内容、但可以出现在必选位上的性质（av1C / pixi / colr 的 ICC 等）。
    Known,
    Unknown,
}

struct Reference {
    kind: [u8; 4],
    from: u32,
    to: Vec<u32>,
}

#[derive(Clone, Copy)]
struct Clap {
    x: usize,
    y: usize,
    w: u32,
    h: u32,
}

struct AvifFile<'a> {
    primary: u32,
    items: Vec<Item>,
    properties: Vec<Property>,
    /// `(item_id, 性质下标（0 起）)`，保持 `ipma` 里的顺序。
    associations: Vec<(u32, usize)>,
    references: Vec<Reference>,
    idat: &'a [u8],
}

fn parse(data: &[u8]) -> R<AvifFile<'_>> {
    if !is_avif(data) {
        return Err(status::BAD_INPUT);
    }
    let top = children(data, 0, data.len())?;
    let meta = top
        .iter()
        .find(|b| &b.kind == b"meta")
        .ok_or(status::BAD_INPUT)?;
    // meta 是 FullBox：正文前 4 字节是 version / flags。
    let boxes = children(data, meta.body + 4, meta.end)?;
    let mut file = AvifFile {
        primary: 0,
        items: Vec::new(),
        properties: Vec::new(),
        associations: Vec::new(),
        references: Vec::new(),
        idat: &[],
    };
    let mut have_primary = false;
    let mut kinds: Vec<(u32, [u8; 4])> = Vec::new();
    for b in &boxes {
        let body = &data[b.body..b.end];
        match &b.kind {
            b"hdlr" => {
                let mut c = Cursor::new(body);
                c.full_box()?;
                c.u32()?; // pre_defined
                if c.bytes(4)? != b"pict" {
                    return Err(status::BAD_INPUT);
                }
            }
            b"pitm" => {
                let mut c = Cursor::new(body);
                let (v, _) = c.full_box()?;
                file.primary = if v == 0 { c.u16()? as u32 } else { c.u32()? };
                have_primary = true;
            }
            b"iinf" => kinds = parse_iinf(data, b)?,
            b"iloc" => file.items = parse_iloc(body)?,
            b"iprp" => parse_iprp(data, b, &mut file)?,
            b"iref" => file.references = parse_iref(data, b)?,
            b"idat" => file.idat = body,
            _ => {}
        }
    }
    if !have_primary {
        return Err(status::BAD_INPUT);
    }
    // iloc 只有位置；类型来自 iinf。两边都在的物件才算数。
    file.items
        .retain_mut(|item| match kinds.iter().find(|(id, _)| *id == item.id) {
            Some((_, k)) => {
                item.kind = *k;
                true
            }
            None => false,
        });
    Ok(file)
}

fn parse_iinf(data: &[u8], b: &BoxHeader) -> R<Vec<(u32, [u8; 4])>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    let (v, _) = c.full_box()?;
    if v == 0 {
        c.u16()?;
    } else {
        c.u32()?;
    }
    let mut out = Vec::new();
    for infe in children(data, b.body + c.at, b.end)? {
        if &infe.kind != b"infe" {
            continue;
        }
        let mut c = Cursor::new(&data[infe.body..infe.end]);
        let (v, _) = c.full_box()?;
        if v < 2 {
            // v0/v1 没有 item_type，AVIF 不会用。
            continue;
        }
        let id = if v == 2 { c.u16()? as u32 } else { c.u32()? };
        c.u16()?; // item_protection_index
        let kind: [u8; 4] = c.bytes(4)?.try_into().unwrap();
        out.push((id, kind));
    }
    Ok(out)
}

fn parse_iloc(body: &[u8]) -> R<Vec<Item>> {
    let mut c = Cursor::new(body);
    let (v, _) = c.full_box()?;
    if v > 2 {
        return Err(status::BAD_INPUT);
    }
    let a = c.u8()?;
    let b = c.u8()?;
    let (offset_size, length_size, base_offset_size) = (a >> 4, a & 15, b >> 4);
    let index_size = if v >= 1 { b & 15 } else { 0 };
    let count = if v < 2 { c.u16()? as u32 } else { c.u32()? };
    let mut items = Vec::new();
    for _ in 0..count {
        let id = if v < 2 { c.u16()? as u32 } else { c.u32()? };
        let construction = if v >= 1 { (c.u16()? & 15) as u8 } else { 0 };
        c.u16()?; // data_reference_index
        let base_offset = c.uint(base_offset_size)?;
        let n = c.u16()?;
        let mut extents = Vec::new();
        for _ in 0..n {
            c.uint(index_size)?;
            let offset = c.uint(offset_size)?;
            let length = c.uint(length_size)?;
            extents.push(Extent { offset, length });
        }
        items.push(Item {
            id,
            kind: [0; 4],
            construction,
            base_offset,
            extents,
        });
    }
    Ok(items)
}

fn parse_iprp(data: &[u8], b: &BoxHeader, file: &mut AvifFile<'_>) -> R<()> {
    for child in children(data, b.body, b.end)? {
        match &child.kind {
            b"ipco" => {
                for p in children(data, child.body, child.end)? {
                    file.properties
                        .push(parse_property(&p.kind, &data[p.body..p.end])?);
                }
            }
            b"ipma" => {
                let mut c = Cursor::new(&data[child.body..child.end]);
                let (v, flags) = c.full_box()?;
                let n = c.u32()?;
                for _ in 0..n {
                    let id = if v < 1 { c.u16()? as u32 } else { c.u32()? };
                    let count = c.u8()?;
                    for _ in 0..count {
                        let (essential, index) = if flags & 1 != 0 {
                            let x = c.u16()?;
                            (x & 0x8000 != 0, (x & 0x7fff) as usize)
                        } else {
                            let x = c.u8()?;
                            (x & 0x80 != 0, (x & 0x7f) as usize)
                        };
                        if index == 0 {
                            continue;
                        }
                        file.associations.push((id, index - 1));
                        if essential
                            && matches!(file.properties.get(index - 1), Some(Property::Unknown))
                        {
                            // 规范：读者不认识的必选性质 → 不得显示该物件。只在它真被用到时才拒绝，
                            // 见 [AvifFile::check_essential]。
                            file.associations.push((id, usize::MAX));
                        }
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn parse_property(kind: &[u8; 4], body: &[u8]) -> R<Property> {
    let mut c = Cursor::new(body);
    Ok(match kind {
        b"ispe" => {
            c.full_box()?;
            Property::Ispe {
                w: c.u32()?,
                h: c.u32()?,
            }
        }
        b"irot" => Property::Irot(c.u8()? & 3),
        b"imir" => Property::Imir(c.u8()? & 1),
        b"clap" => {
            let mut v = [0u32; 8];
            for x in &mut v {
                *x = c.u32()?;
            }
            Property::Clap(v)
        }
        b"colr" => {
            if c.bytes(4)? == b"nclx" {
                c.u16()?; // colour_primaries
                c.u16()?; // transfer_characteristics
                let matrix = c.u16()?;
                let full = c.u8()? & 0x80 != 0;
                Property::Colr(matrix, full)
            } else {
                Property::Known
            }
        }
        b"auxC" => {
            c.full_box()?;
            let urn = c.cstring()?;
            if urn == b"urn:mpeg:mpegB:cicp:systems:auxiliary:alpha"
                || urn == b"urn:mpeg:hevc:2015:auxid:1"
            {
                Property::AuxAlpha
            } else {
                Property::Known
            }
        }
        b"av1C" | b"pixi" | b"pasp" | b"clli" | b"mdcv" | b"a1op" | b"lsel" | b"a1lx" => {
            Property::Known
        }
        _ => Property::Unknown,
    })
}

fn parse_iref(data: &[u8], b: &BoxHeader) -> R<Vec<Reference>> {
    let mut c = Cursor::new(&data[b.body..b.end]);
    let (v, _) = c.full_box()?;
    let mut out = Vec::new();
    for r in children(data, b.body + 4, b.end)? {
        let mut c = Cursor::new(&data[r.body..r.end]);
        let id = |c: &mut Cursor| -> R<u32> {
            if v == 0 {
                Ok(c.u16()? as u32)
            } else {
                c.u32()
            }
        };
        let from = id(&mut c)?;
        let n = c.u16()?;
        let mut to = Vec::with_capacity(n as usize);
        for _ in 0..n {
            to.push(id(&mut c)?);
        }
        out.push(Reference {
            kind: r.kind,
            from,
            to,
        });
    }
    Ok(out)
}

#[derive(Clone, Copy, PartialEq)]
enum Plane {
    Color,
    Alpha,
}

/// 解出来的一张（瓦片或整图）：Color 时 `px` 是 RGB 三通道，Alpha 时单通道。
struct Decoded {
    w: usize,
    h: usize,
    px: Vec<u8>,
}

impl<'a> AvifFile<'a> {
    fn item(&self, id: u32) -> R<&Item> {
        self.items
            .iter()
            .find(|i| i.id == id)
            .ok_or(status::BAD_INPUT)
    }

    fn props(&self, id: u32) -> impl Iterator<Item = &Property> {
        self.associations
            .iter()
            .filter(move |(i, _)| *i == id)
            .filter_map(|(_, p)| self.properties.get(*p))
    }

    fn check_essential(&self, id: u32) -> R<()> {
        if self
            .associations
            .iter()
            .any(|(i, p)| *i == id && *p == usize::MAX)
        {
            return Err(status::BAD_INPUT);
        }
        Ok(())
    }

    fn ispe(&self, id: u32) -> Option<(u32, u32)> {
        self.props(id).find_map(|p| match p {
            Property::Ispe { w, h } => Some((*w, *h)),
            _ => None,
        })
    }

    fn rotation(&self, id: u32) -> u8 {
        self.props(id)
            .find_map(|p| match p {
                Property::Irot(a) => Some(*a),
                _ => None,
            })
            .unwrap_or(0)
    }

    fn mirror(&self, id: u32) -> Option<u8> {
        self.props(id).find_map(|p| match p {
            Property::Imir(a) => Some(*a),
            _ => None,
        })
    }

    fn colr(&self, id: u32) -> Option<(u16, bool)> {
        self.props(id).find_map(|p| match p {
            Property::Colr(m, f) => Some((*m, *f)),
            _ => None,
        })
    }

    /// `clap` 算出的裁剪框（ISO/IEC 14496-12 §12.1.4：中心 = (W-1)/2 + 偏移）。
    /// 不合法（非整数像素、越界）时忽略，按整图显示——与 libavif 的宽松模式一致。
    fn clap(&self, id: u32) -> Option<Clap> {
        let v = self.props(id).find_map(|p| match p {
            Property::Clap(v) => Some(*v),
            _ => None,
        })?;
        let (cw, ch) = self.coded_size(self.item(id).ok()?).ok()?;
        let [wn, wd, hn, hd, xn, xd, yn, yd] = v;
        if wd == 0 || hd == 0 || xd == 0 || yd == 0 || wn % wd != 0 || hn % hd != 0 {
            return None;
        }
        let (w, h) = ((wn / wd) as i64, (hn / hd) as i64);
        // 偏移分子是有符号数。左上角 x = (W - w)/2 + off，用 2·分母 通分后要求整除。
        let x2d = (cw as i64 - w) * xd as i64 + 2 * (xn as i32) as i64;
        let y2d = (ch as i64 - h) * yd as i64 + 2 * (yn as i32) as i64;
        if x2d % (2 * xd as i64) != 0 || y2d % (2 * yd as i64) != 0 {
            return None;
        }
        let (x, y) = (x2d / (2 * xd as i64), y2d / (2 * yd as i64));
        if w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > cw as i64 || y + h > ch as i64 {
            return None;
        }
        Some(Clap {
            x: x as usize,
            y: y as usize,
            w: w as u32,
            h: h as u32,
        })
    }

    fn premultiplied(&self, color: u32) -> bool {
        self.references
            .iter()
            .any(|r| &r.kind == b"prem" && r.from == color)
    }

    /// 指向 [color] 的 alpha 辅助图（`auxl` 引用、`auxC` 为 alpha）。
    fn alpha_for(&self, color: u32) -> Option<u32> {
        self.references
            .iter()
            .filter(|r| &r.kind == b"auxl" && r.to.contains(&color))
            .map(|r| r.from)
            .find(|&id| self.props(id).any(|p| matches!(p, Property::AuxAlpha)))
    }

    fn tiles(&self, grid: u32) -> R<&[u32]> {
        self.references
            .iter()
            .find(|r| &r.kind == b"dimg" && r.from == grid)
            .map(|r| r.to.as_slice())
            .ok_or(status::BAD_INPUT)
    }

    /// 编码尺寸：`av01` 取 `ispe`；`grid` 取网格描述里的输出尺寸。
    fn coded_size(&self, item: &Item) -> R<(u32, u32)> {
        match &item.kind {
            b"grid" => {
                let g = self.grid(item)?;
                Ok((g.w, g.h))
            }
            b"av01" => self.ispe(item.id).ok_or(status::BAD_INPUT),
            _ => Err(status::BAD_INPUT),
        }
    }

    fn grid(&self, item: &Item) -> R<Grid> {
        let body = self.payload_of(item)?;
        let mut c = Cursor::new(&body);
        c.u8()?; // version
        let flags = c.u8()?;
        let rows = c.u8()? as usize + 1;
        let cols = c.u8()? as usize + 1;
        let (w, h) = if flags & 1 == 0 {
            (c.u16()? as u32, c.u16()? as u32)
        } else {
            (c.u32()?, c.u32()?)
        };
        Ok(Grid { rows, cols, w, h })
    }

    /// 物件数据（按 `iloc` 拼 extent）。这里只用于小块数据（grid 描述）；AV1 帧走 [Self::payload]。
    fn payload_of(&self, item: &Item) -> R<Vec<u8>> {
        let src: &[u8] = match item.construction {
            1 => self.idat,
            _ => return Err(status::BAD_INPUT),
        };
        self.collect(item, src)
    }

    fn payload(&self, data: &[u8], item: &Item) -> R<Vec<u8>> {
        let src: &[u8] = match item.construction {
            0 => data,
            1 => self.idat,
            _ => return Err(status::BAD_INPUT),
        };
        self.collect(item, src)
    }

    fn collect(&self, item: &Item, src: &[u8]) -> R<Vec<u8>> {
        let mut out = Vec::new();
        for e in &item.extents {
            let start = item
                .base_offset
                .checked_add(e.offset)
                .ok_or(status::BAD_INPUT)?;
            let end = if e.length == 0 {
                src.len() as u64
            } else {
                start.checked_add(e.length).ok_or(status::BAD_INPUT)?
            };
            if start > end || end > src.len() as u64 {
                return Err(status::BAD_INPUT);
            }
            out.extend_from_slice(&src[start as usize..end as usize]);
        }
        Ok(out)
    }

    fn decode_item(
        &self,
        data: &[u8],
        item: &Item,
        decoder: &mut Av1Decoder,
        plane: Plane,
    ) -> R<Decoded> {
        self.check_essential(item.id)?;
        match &item.kind {
            b"av01" => {
                let bytes = if item.construction == 1 {
                    self.payload_of(item)?
                } else {
                    self.payload(data, item)?
                };
                let frame = decoder.decode(&bytes)?;
                let (matrix, full) = match plane {
                    Plane::Color => self
                        .colr(item.id)
                        .map(|(m, f)| (m as u32, f))
                        .unwrap_or((frame.matrix, frame.full_range)),
                    Plane::Alpha => (frame.matrix, frame.full_range),
                };
                Ok(match plane {
                    Plane::Color => Decoded {
                        w: frame.w,
                        h: frame.h,
                        px: frame.to_rgb8(matrix, full),
                    },
                    Plane::Alpha => Decoded {
                        w: frame.w,
                        h: frame.h,
                        px: frame.luma8(full),
                    },
                })
            }
            b"grid" => {
                let g = self.grid(item)?;
                let tiles = self.tiles(item.id)?;
                if tiles.len() != g.rows * g.cols || tiles.len() > MAX_TILES {
                    return Err(status::BAD_INPUT);
                }
                let (w, h) = (g.w as usize, g.h as usize);
                if w == 0 || h == 0 || (w as u64) * (h as u64) > MAX_PIXELS {
                    return Err(status::BAD_INPUT);
                }
                let ch = if plane == Plane::Color { 3 } else { 1 };
                let mut px = vec![0u8; w * h * ch];
                let (mut tw, mut th) = (0usize, 0usize);
                for (n, &id) in tiles.iter().enumerate() {
                    let tile_item = self.item(id)?;
                    if &tile_item.kind != b"av01" {
                        return Err(status::BAD_INPUT);
                    }
                    let tile = self.decode_item(data, tile_item, decoder, plane)?;
                    if n == 0 {
                        (tw, th) = (tile.w, tile.h);
                        // 规范：瓦片同尺寸、铺满（可超出）输出画布，且最后一行 / 列必须与画布相交。
                        if tw * g.cols < w
                            || th * g.rows < h
                            || tw * (g.cols - 1) >= w
                            || th * (g.rows - 1) >= h
                        {
                            return Err(status::BAD_INPUT);
                        }
                    } else if tile.w != tw || tile.h != th {
                        return Err(status::BAD_INPUT);
                    }
                    let (x0, y0) = ((n % g.cols) * tw, (n / g.cols) * th);
                    let cw = tw.min(w - x0);
                    for row in 0..th.min(h - y0) {
                        let src = &tile.px[row * tw * ch..(row * tw + cw) * ch];
                        let dst = ((y0 + row) * w + x0) * ch;
                        px[dst..dst + cw * ch].copy_from_slice(src);
                    }
                }
                Ok(Decoded { w, h, px })
            }
            _ => Err(status::BAD_INPUT),
        }
    }
}

struct Grid {
    rows: usize,
    cols: usize,
    w: u32,
    h: u32,
}

// ---------------------------------------------------------------------------
// 变换（clap / irot / imir）
// ---------------------------------------------------------------------------

struct Canvas {
    ch: usize,
    w: usize,
    h: usize,
    px: Vec<u8>,
}

impl Canvas {
    fn crop(self, x: usize, y: usize, w: usize, h: usize) -> Canvas {
        let mut px = Vec::with_capacity(w * h * self.ch);
        for row in y..y + h {
            let s = (row * self.w + x) * self.ch;
            px.extend_from_slice(&self.px[s..s + w * self.ch]);
        }
        Canvas {
            ch: self.ch,
            w,
            h,
            px,
        }
    }

    /// 逆时针转 90°（`irot` 的方向）：新图 (x', y') = 旧图 (W-1-y', x')。
    fn rotate_ccw(self) -> Canvas {
        let (w, h, ch) = (self.h, self.w, self.ch);
        let mut px = vec![0u8; self.px.len()];
        for y in 0..h {
            for x in 0..w {
                let src = (x * self.w + (self.w - 1 - y)) * ch;
                let dst = (y * w + x) * ch;
                px[dst..dst + ch].copy_from_slice(&self.px[src..src + ch]);
            }
        }
        Canvas { ch, w, h, px }
    }

    /// 左右翻（`imir` axis = 1）。
    fn flip_horizontal(&mut self) {
        let ch = self.ch;
        for row in self.px.chunks_exact_mut(self.w * ch) {
            for x in 0..self.w / 2 {
                let (a, b) = (x * ch, (self.w - 1 - x) * ch);
                for k in 0..ch {
                    row.swap(a + k, b + k);
                }
            }
        }
    }

    /// 上下翻（`imir` axis = 0）。
    fn flip_vertical(&mut self) {
        let stride = self.w * self.ch;
        for y in 0..self.h / 2 {
            let (top, bottom) = self.px.split_at_mut((self.h - 1 - y) * stride);
            top[y * stride..(y + 1) * stride].swap_with_slice(&mut bottom[..stride]);
        }
    }
}

// ---------------------------------------------------------------------------
// AV1 帧（rav1d）与 YUV → RGB
// ---------------------------------------------------------------------------

/// 一帧 YUV，平面拷成自有的 u16（8 位也放 u16，省一套泛型）。
struct Frame {
    w: usize,
    h: usize,
    depth: u32,
    /// 色度下采样位移 `(水平, 竖直)`；`None` = 单色 4:0:0。
    chroma: Option<(usize, usize)>,
    y: Vec<u16>,
    u: Vec<u16>,
    v: Vec<u16>,
    /// AV1 序列头里的 CICP 矩阵系数与范围（容器 `colr` 优先，由调用方决定）。
    matrix: u32,
    full_range: bool,
}

impl Frame {
    /// 单通道 8 位（alpha 用）：限制范围按 16..235 拉伸。
    fn luma8(&self, full: bool) -> Vec<u8> {
        let max = ((1u32 << self.depth) - 1) as f32;
        let lo = (16u32 << (self.depth - 8)) as f32;
        let span = (219u32 << (self.depth - 8)) as f32;
        self.y
            .iter()
            .map(|&s| {
                let n = if full {
                    s as f32 / max
                } else {
                    (s as f32 - lo) / span
                };
                (n * 255.0).round().clamp(0.0, 255.0) as u8
            })
            .collect()
    }

    fn to_rgb8(&self, matrix: u32, full: bool) -> Vec<u8> {
        let d = self.depth;
        let max = ((1u32 << d) - 1) as f32;
        let mid = (1u32 << (d - 1)) as f32;
        let (y_lo, y_span, c_span) = if full {
            (0.0, max, max)
        } else {
            (
                (16u32 << (d - 8)) as f32,
                (219u32 << (d - 8)) as f32,
                (224u32 << (d - 8)) as f32,
            )
        };
        // CICP 矩阵系数（ITU-T H.273 表 4）。未指定 / 不认识的按 BT.601（libavif 同此）。
        let (kr, kb) = match matrix {
            1 => (0.2126, 0.0722),
            4 => (0.30, 0.11),
            7 => (0.212, 0.087),
            9 | 10 => (0.2627, 0.0593),
            _ => (0.299, 0.114),
        };
        let kg = 1.0 - kr - kb;
        let mut out = vec![0u8; self.w * self.h * 3];
        let to8 = |x: f32| (x * 255.0).round().clamp(0.0, 255.0) as u8;
        let (u, v) = match self.chroma {
            Some((sx, sy)) => (
                self.upsample(&self.u, sx, sy),
                self.upsample(&self.v, sx, sy),
            ),
            None => (Vec::new(), Vec::new()),
        };
        for row in 0..self.h {
            for col in 0..self.w {
                let i = row * self.w + col;
                let yv = (self.y[i] as f32 - y_lo) / y_span;
                let (r, g, b) = match self.chroma {
                    None => (yv, yv, yv),
                    Some(_) => {
                        let cb = (u[i] - mid) / c_span;
                        let cr = (v[i] - mid) / c_span;
                        match matrix {
                            // 恒等矩阵：平面依次是 G、B、R。
                            0 => (v[i] / max, self.y[i] as f32 / max, u[i] / max),
                            // YCgCo：U = Cg，V = Co。
                            8 => {
                                let t = yv - cb;
                                (t + cr, yv + cb, t - cr)
                            }
                            _ => {
                                let r = yv + (2.0 - 2.0 * kr) * cr;
                                let b = yv + (2.0 - 2.0 * kb) * cb;
                                (r, (yv - kr * r - kb * b) / kg, b)
                            }
                        }
                    }
                };
                let o = i * 3;
                out[o] = to8(r);
                out[o + 1] = to8(g);
                out[o + 2] = to8(b);
            }
        }
        out
    }

    /// 色度平面上采样到亮度尺寸：下采样的方向按中心采样位置做双线性（3:1 权重、边缘夹取），
    /// 与 libavif 默认的 libyuv 双线性一致；不下采样的方向原样取。
    fn upsample(&self, plane: &[u16], sx: usize, sy: usize) -> Vec<f32> {
        let cw = (self.w + (1 << sx) - 1) >> sx;
        let chh = (self.h + (1 << sy) - 1) >> sy;
        // 输出坐标 → (近邻下标, 远邻下标)；远邻权重 1/4。
        let taps = |n: usize, shift: usize, len: usize| -> (usize, usize) {
            if shift == 0 {
                return (n, n);
            }
            let i = n >> 1;
            let far = if n & 1 == 0 {
                i.saturating_sub(1)
            } else {
                (i + 1).min(len - 1)
            };
            (i, far)
        };
        let mut horizontal = vec![0f32; self.w * chh];
        for r in 0..chh {
            let src = &plane[r * cw..(r + 1) * cw];
            for x in 0..self.w {
                let (near, far) = taps(x, sx, cw);
                horizontal[r * self.w + x] = (3.0 * src[near] as f32 + src[far] as f32) / 4.0;
            }
        }
        let mut out = vec![0f32; self.w * self.h];
        for y in 0..self.h {
            let (near, far) = taps(y, sy, chh);
            for x in 0..self.w {
                out[y * self.w + x] =
                    (3.0 * horizontal[near * self.w + x] + horizontal[far * self.w + x]) / 4.0;
            }
        }
        out
    }
}

/// rav1d 的 Rust API（`rav1d::Decoder`）。不走 `dav1d_*` 那套 `extern "C"` 入口：那里面一旦
/// panic 就不可 unwind、整个进程 abort。Rust API 里的 panic 照常 unwind，由 [decode_guarded]
/// 接住转成 BAD_INPUT。
struct Av1Decoder {
    /// 出错 unwind 时不析构（析构要调 `rav1d_close`，若在 unwind 途中再 panic 就是 abort），
    /// 只在正常结束时由 [decode_guarded] 显式释放；坏码流撞上 rav1d 的 bug 时宁可漏一个上下文。
    inner: ManuallyDrop<rav1d::Decoder>,
}

impl Av1Decoder {
    fn new() -> R<Self> {
        let mut settings = rav1d::Settings::new();
        // 单线程：解码同步跑在调用线程上，worker 线程里的 panic 不会让这里死等；调用方（Dart 侧）
        // 本来就在后台 isolate 里按页并发。
        settings.set_n_threads(1);
        // 静态图一次一帧，没有流水线可言：单帧上下文让解出的帧立即可取。
        settings.set_max_frame_delay(1);
        // 胶片颗粒是图像的一部分（浏览器 / libavif 都合成）。
        settings.set_apply_grain(true);
        settings.set_frame_size_limit(MAX_PIXELS.min(u32::MAX as u64) as u32);
        let inner = rav1d::Decoder::with_settings(&settings).map_err(|_| status::BAD_INPUT)?;
        Ok(Self {
            inner: ManuallyDrop::new(inner),
        })
    }

    /// 送入一个 AVIF 物件（一个时间单元）并取出完整的一帧（分层图取最后一层）。
    fn decode(&mut self, av1: &[u8]) -> R<Frame> {
        use rav1d::Rav1dError::TryAgain;
        if av1.is_empty() {
            return Err(status::BAD_INPUT);
        }
        let dec = &mut *self.inner;
        let mut last: Option<rav1d::Picture> = None;
        let mut sent = dec.send_data(av1.to_vec().into_boxed_slice(), None, None, None);
        // 解码器手里还压着帧（TryAgain）：先取出再继续送。单帧上下文下最多转几圈。
        for _ in 0..64 {
            match sent {
                Err(TryAgain) => {
                    match dec.get_picture() {
                        Ok(p) => last = Some(p),
                        Err(TryAgain) => {}
                        Err(_) => return Err(status::BAD_INPUT),
                    }
                    sent = dec.send_pending_data();
                }
                _ => break,
            }
        }
        if sent.is_err() {
            return Err(status::BAD_INPUT);
        }
        loop {
            match dec.get_picture() {
                Ok(p) => last = Some(p),
                Err(TryAgain) => break,
                Err(_) => return Err(status::BAD_INPUT),
            }
        }
        copy_frame(&last.ok_or(status::BAD_INPUT)?)
    }

    /// 丢弃解码器里在途的数据与帧（图像序列循环回第 0 个样本前调用）。
    fn flush(&mut self) {
        self.inner.flush();
    }

    /// rav1d panic 过之后调用：上下文状态不可信，不析构（inner 是 ManuallyDrop），只泄漏。
    fn leak(self) {}

    fn close(mut self) {
        // SAFETY: 只在正常结束时调用一次，之后 `self` 被消耗。
        unsafe { ManuallyDrop::drop(&mut self.inner) };
    }
}

/// 在 catch_unwind 里跑一次解码；rav1d 内部 panic → BAD_INPUT（解码器上下文泄漏，见 [Av1Decoder]）。
fn decode_guarded<T>(body: impl FnOnce(&mut Av1Decoder) -> R<T>) -> R<T> {
    let mut decoder = Av1Decoder::new()?;
    match catch_unwind(AssertUnwindSafe(|| body(&mut decoder))) {
        Ok(result) => {
            decoder.close();
            result
        }
        Err(_) => Err(status::BAD_INPUT),
    }
}

/// 把 rav1d 的帧平面拷成自有内存（8 位也放 u16）。
fn copy_frame(pic: &rav1d::Picture) -> R<Frame> {
    use rav1d::PlanarImageComponent as C;
    let (w, h) = (pic.width() as usize, pic.height() as usize);
    let depth = pic.bit_depth() as u32;
    if w == 0 || h == 0 || !(8..=12).contains(&depth) {
        return Err(status::BAD_INPUT);
    }
    let chroma = match pic.pixel_layout() {
        rav1d::PixelLayout::I400 => None,
        rav1d::PixelLayout::I420 => Some((1, 1)),
        rav1d::PixelLayout::I422 => Some((1, 0)),
        rav1d::PixelLayout::I444 => Some((0, 0)),
    };
    let bytes = if depth > 8 { 2 } else { 1 };
    let plane = |c: C, pw: usize, ph: usize| -> R<Vec<u16>> {
        let stride = pic.stride(c) as usize;
        let data = pic.plane(c);
        if stride < pw * bytes || data.len() < stride * (ph - 1) + pw * bytes {
            return Err(status::BAD_INPUT);
        }
        let mut out = Vec::with_capacity(pw * ph);
        for row in 0..ph {
            let line = &data[row * stride..row * stride + pw * bytes];
            if bytes == 1 {
                out.extend(line.iter().map(|&x| x as u16));
            } else {
                out.extend(
                    line.chunks_exact(2)
                        .map(|b| u16::from_ne_bytes([b[0], b[1]])),
                );
            }
        }
        Ok(out)
    };
    let y = plane(C::Y, w, h)?;
    let (u, v) = match chroma {
        None => (Vec::new(), Vec::new()),
        Some((sx, sy)) => {
            let (cw, chh) = ((w + (1 << sx) - 1) >> sx, (h + (1 << sy) - 1) >> sy);
            (plane(C::U, cw, chh)?, plane(C::V, cw, chh)?)
        }
    };
    let matrix = pic.matrix_coefficients() as u32;
    let full_range = pic.color_range() == rav1d::pixel::YUVRange::Full;
    Ok(Frame {
        w,
        h,
        depth,
        chroma,
        y,
        u,
        v,
        matrix,
        full_range,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> Vec<u8> {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/fushi_engine/test/media/image_kernels/fixtures/avif");
        std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
    }

    /// 参考 PNG（libavif 解码 / 按规范拼裁）→ 与解码结果同通道数的 uint8。
    fn reference(name: &str, ch: u32) -> (Vec<u8>, u32, u32) {
        let img = ::image::load_from_memory(&fixture(&format!("{name}.ref.png"))).unwrap();
        let (w, h) = (img.width(), img.height());
        let px = if ch == 4 {
            img.into_rgba8().into_raw()
        } else {
            img.into_rgb8().into_raw()
        };
        (px, w, h)
    }

    /// `(最大差, 平均差)`。
    fn compare(name: &str) -> (u8, f64) {
        let (px, w, h, ch) = decode(&fixture(&format!("{name}.avif"))).unwrap();
        let (want, rw, rh) = reference(name, ch);
        assert_eq!((w, h), (rw, rh), "{name} 尺寸");
        assert_eq!(
            probe(&fixture(&format!("{name}.avif"))).unwrap(),
            (w, h),
            "{name} probe"
        );
        let mut max = 0u8;
        let mut sum = 0u64;
        for (a, b) in px.iter().zip(&want) {
            let d = a.abs_diff(*b);
            max = max.max(d);
            sum += d as u64;
        }
        (max, sum as f64 / px.len() as f64)
    }

    /// 与 libavif 的差：YUV → RGB 的定点 / 浮点取整差 ±1；10 位降 8 位时 libavif 先在高位深
    /// 转 RGB 再截断，差到 4。2026-10-20 实测：rgb420 2 / 0.35，ten_bit 4 / 0.99，其余 ≤ 1 / 0.13。
    #[test]
    fn matches_libavif_reference_pixels() {
        for (name, max_ok, mean_ok) in [
            ("rgb420", 3, 0.5),
            ("rgb444", 1, 0.2),
            ("rgba", 1, 0.2),
            ("orient2", 1, 0.2),
            ("orient6", 1, 0.2),
            ("orient7", 1, 0.2),
            ("ten_bit", 4, 1.2),
            ("gray", 1, 0.2),
            ("grid", 1, 0.2),
            ("clap_rot", 1, 0.2),
        ] {
            let (max, mean) = compare(name);
            assert!(
                max <= max_ok && mean <= mean_ok,
                "{name}: max {max} mean {mean:.3}"
            );
        }
    }

    #[test]
    fn alpha_yields_four_channels_and_opaque_yields_three() {
        assert_eq!(decode(&fixture("rgba.avif")).unwrap().3, 4);
        assert_eq!(decode(&fixture("rgb444.avif")).unwrap().3, 3);
        assert_eq!(decode(&fixture("gray.avif")).unwrap().3, 3);
    }

    #[test]
    fn rotation_swaps_probed_size() {
        // 40×24 的源图，irot 3 → 24×40；clap 40×30 + irot 1 → 30×40。
        assert_eq!(probe(&fixture("orient6.avif")).unwrap(), (24, 40));
        assert_eq!(probe(&fixture("orient2.avif")).unwrap(), (40, 24));
        assert_eq!(probe(&fixture("clap_rot.avif")).unwrap(), (30, 40));
        assert_eq!(probe(&fixture("grid.avif")).unwrap(), (72, 60));
    }

    #[test]
    fn other_formats_are_not_avif() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/fushi_engine/test/media/image_kernels/fixtures");
        for name in ["gray.jpg", "lossy.webp", "std24.bmp"] {
            assert!(!is_avif(&std::fs::read(dir.join(name)).unwrap()), "{name}");
        }
        assert!(!is_avif(b""));
        assert!(!is_avif(b"\0\0\0\x0cftypheic\0\0\0\0"));
    }

    #[test]
    fn truncated_files_fail_cleanly() {
        for name in ["grid.avif", "rgba.avif", "clap_rot.avif"] {
            let data = fixture(name);
            for len in 0..data.len() {
                let cut = &data[..len];
                let r = std::panic::catch_unwind(|| (decode(cut).err(), probe(cut).err()));
                assert!(r.is_ok(), "{name} 截到 {len} 字节时 panic");
            }
        }
    }

    /// rav1d 的入口是 `extern "C"`：里面一旦 panic 就不可 unwind、整个进程 abort（`guard` 的
    /// catch_unwind 接不住），所以这里拿坏码流逐字节轰一遍。跑挂的表现是测试进程直接退出。
    #[test]
    fn corrupt_av1_payload_does_not_abort() {
        for name in [
            "rgba.avif",
            "rgb420.avif",
            "ten_bit.avif",
            "gray.avif",
            "grid.avif",
        ] {
            let data = fixture(name);
            let mdat = data.windows(4).rposition(|w| w == b"mdat").unwrap() + 4;
            for at in mdat..data.len() {
                for flip in [0xa5u8, 0xff, 0x01] {
                    let mut bad = data.clone();
                    bad[at] ^= flip;
                    let _ = decode(&bad);
                }
            }
            // 整段 AV1 换成伪随机字节（固定种子）。
            let mut seed = 0x9e37_79b9_u32;
            for _ in 0..64 {
                let mut bad = data.clone();
                for b in &mut bad[mdat..] {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    *b = seed as u8;
                }
                let _ = decode(&bad);
            }
        }
    }

    /// 手动基准：`FUSHI_AVIF_BENCH=<文件> cargo test --release --lib bench_avif -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn bench_avif() {
        let data = std::fs::read(std::env::var("FUSHI_AVIF_BENCH").unwrap()).unwrap();
        let t = std::time::Instant::now();
        let (_, w, h, ch) = decode(&data).unwrap();
        println!("{w}x{h}x{ch}: {:?}", t.elapsed());
    }

    #[test]
    fn unknown_essential_property_is_rejected() {
        // 把 clap_rot 里的 `clap` 改名成不认识的 `xxxx`：它在 ipma 里标成必选，按规范不得显示。
        let mut data = fixture("clap_rot.avif");
        let at = data.windows(4).position(|w| w == b"clap").unwrap();
        data[at..at + 4].copy_from_slice(b"xxxx");
        assert_eq!(decode(&data).err(), Some(status::BAD_INPUT));
    }
}

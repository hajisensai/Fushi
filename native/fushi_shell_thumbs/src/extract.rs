//! 从一个文件字节流里取封面缩略图：识别容器 → 选封面 → 解码缩放。

use std::io::Read;

use zip::ZipArchive;

use crate::cover::{
    CoverRef, comic_cover_order, container_rootfile, epub_cover_candidates, first_image_in_page,
    parse_opf,
};
use crate::image_out::{MAX_COVER_BYTES, thumbnail_from_image_bytes};
use crate::sniff::{ContainerKind, sniff};
use crate::{ReadSeek, ThumbError, Thumbnail};

/// epub 里 XML 文件（container.xml / OPF / 封面页）的体积上限。
const MAX_XML_BYTES: u64 = 8 * 1024 * 1024;

/// 一张图解不开时最多再试几张（坏页 / 不支持的编码）。
const MAX_IMAGE_ATTEMPTS: usize = 6;

/// 打开后的归档：按下标读条目。
pub trait ArchiveSession {
    /// 条目路径（目录条目也在内，调用方自己过滤），下标即 [`ArchiveSession::read`] 的参数。
    fn names(&self) -> &[String];
    /// 读出一个条目的全部字节；超过 `max` 字节按坏文件处理。
    fn read(&mut self, index: usize, max: u64) -> Result<Vec<u8>, ThumbError>;
}

/// rar / 7z 的解包后端（Windows 上是随包的 7z.dll）。
pub trait ArchiveBackend {
    fn open(
        &self,
        kind: ContainerKind,
        reader: Box<dyn ReadSeek>,
    ) -> Result<Box<dyn ArchiveSession>, ThumbError>;
}

/// pdf 首页渲染后端（Windows 上是随包的 pdfium.dll）。
pub trait PdfBackend {
    fn render_first_page(
        &self,
        reader: Box<dyn ReadSeek>,
        cx: u32,
    ) -> Result<Thumbnail, ThumbError>;
}

/// 可选的外部后端；缺哪个，对应格式就回 [`ThumbError::MissingDependency`]。
#[derive(Default, Clone, Copy)]
pub struct Backends<'a> {
    pub archive: Option<&'a dyn ArchiveBackend>,
    pub pdf: Option<&'a dyn PdfBackend>,
}

/// 入口：给一个可寻址字节流和资源管理器要的边长，返回封面缩略图。
pub fn extract_thumbnail(
    mut reader: Box<dyn ReadSeek>,
    cx: u32,
    backends: Backends<'_>,
) -> Result<Thumbnail, ThumbError> {
    match sniff(reader.as_mut())? {
        ContainerKind::Zip => {
            let mut zip = ZipSession::open(reader)?;
            if zip.is_epub() {
                if let Ok(t) = epub_cover(&mut zip, cx) {
                    return Ok(t);
                }
            }
            comic_cover(&mut zip, cx)
        }
        kind @ (ContainerKind::Rar4 | ContainerKind::Rar5 | ContainerKind::SevenZip) => {
            let backend = backends
                .archive
                .ok_or_else(|| ThumbError::MissingDependency("7z.dll".into()))?;
            let mut session = backend.open(kind, reader)?;
            comic_cover(session.as_mut(), cx)
        }
        ContainerKind::Pdf => backends
            .pdf
            .ok_or_else(|| ThumbError::MissingDependency("pdfium.dll".into()))?
            .render_first_page(reader, cx),
    }
}

/// 漫画包：按 [`comic_cover_order`] 顺次试，第一张能解的就是封面。
fn comic_cover(session: &mut dyn ArchiveSession, cx: u32) -> Result<Thumbnail, ThumbError> {
    let order = comic_cover_order(session.names());
    let mut last = ThumbError::NoCover;
    for index in order.into_iter().take(MAX_IMAGE_ATTEMPTS) {
        match session
            .read(index, MAX_COVER_BYTES)
            .and_then(|bytes| thumbnail_from_image_bytes(&bytes, cx))
        {
            Ok(t) => return Ok(t),
            Err(e) => last = e,
        }
    }
    Err(last)
}

fn epub_cover(zip: &mut ZipSession, cx: u32) -> Result<Thumbnail, ThumbError> {
    let container = zip
        .read_path("META-INF/container.xml", MAX_XML_BYTES)
        .ok_or(ThumbError::NoCover)?;
    let opf_path = container_rootfile(&container).ok_or(ThumbError::NoCover)?;
    let opf_xml = zip
        .read_path(&opf_path, MAX_XML_BYTES)
        .ok_or(ThumbError::NoCover)?;
    let opf = parse_opf(&opf_xml, &opf_path);
    let mut attempts = 0;
    for candidate in epub_cover_candidates(&opf) {
        let image_path = match candidate {
            CoverRef::Image(p) => Some(p),
            CoverRef::Page(page) => zip
                .read_path(&page, MAX_XML_BYTES)
                .and_then(|xml| first_image_in_page(&xml, &page)),
        };
        let Some(image_path) = image_path else {
            continue;
        };
        let Some(bytes) = zip.read_path(&image_path, MAX_COVER_BYTES) else {
            continue;
        };
        attempts += 1;
        if let Ok(t) = thumbnail_from_image_bytes(&bytes, cx) {
            return Ok(t);
        }
        if attempts >= MAX_IMAGE_ATTEMPTS {
            break;
        }
    }
    Err(ThumbError::NoCover)
}

/// zip（cbz / epub）会话，纯 Rust。
pub struct ZipSession {
    zip: ZipArchive<Box<dyn ReadSeek>>,
    names: Vec<String>,
}

impl ZipSession {
    pub fn open(reader: Box<dyn ReadSeek>) -> Result<Self, ThumbError> {
        let zip = ZipArchive::new(reader).map_err(|e| ThumbError::Corrupt(e.to_string()))?;
        let names = (0..zip.len())
            .map(|i| zip.name_for_index(i).unwrap_or_default().to_string())
            .collect();
        Ok(ZipSession { zip, names })
    }

    fn is_epub(&self) -> bool {
        self.index_of("META-INF/container.xml").is_some()
    }

    /// 精确匹配优先，其次不区分大小写（有的 epub 生成器 href 大小写与实际条目不一致）。
    fn index_of(&self, path: &str) -> Option<usize> {
        self.names
            .iter()
            .position(|n| n == path)
            .or_else(|| self.names.iter().position(|n| n.eq_ignore_ascii_case(path)))
    }

    fn read_path(&mut self, path: &str, max: u64) -> Option<Vec<u8>> {
        let i = self.index_of(path)?;
        self.read(i, max).ok()
    }
}

impl ArchiveSession for ZipSession {
    fn names(&self) -> &[String] {
        &self.names
    }

    fn read(&mut self, index: usize, max: u64) -> Result<Vec<u8>, ThumbError> {
        let entry = self
            .zip
            .by_index(index)
            .map_err(|e| ThumbError::Corrupt(e.to_string()))?;
        if entry.is_dir() {
            return Err(ThumbError::NoCover);
        }
        if entry.size() > max {
            return Err(ThumbError::Corrupt(format!(
                "entry larger than {max} bytes"
            )));
        }
        let mut out = Vec::with_capacity(entry.size() as usize);
        entry.take(max + 1).read_to_end(&mut out)?;
        if out.len() as u64 > max {
            return Err(ThumbError::Corrupt(format!(
                "entry larger than {max} bytes"
            )));
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
    use std::io::{Cursor, Write};
    use zip::write::SimpleFileOptions;

    fn png(w: u32, h: u32, rgb: [u8; 3]) -> Vec<u8> {
        let img = RgbaImage::from_pixel(w, h, Rgba([rgb[0], rgb[1], rgb[2], 255]));
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(img)
            .write_to(&mut out, ImageFormat::Png)
            .unwrap();
        out.into_inner()
    }

    fn zip_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, data) in entries {
            if name.ends_with('/') {
                w.add_directory(*name, SimpleFileOptions::default())
                    .unwrap();
            } else {
                w.start_file(*name, SimpleFileOptions::default()).unwrap();
                w.write_all(data).unwrap();
            }
        }
        w.finish().unwrap().into_inner()
    }

    fn run(bytes: Vec<u8>, cx: u32) -> Result<Thumbnail, ThumbError> {
        extract_thumbnail(Box::new(Cursor::new(bytes)), cx, Backends::default())
    }

    fn first_pixel_rgb(t: &Thumbnail) -> [u8; 3] {
        [t.bgra[2], t.bgra[1], t.bgra[0]]
    }

    #[test]
    fn cbz_uses_first_page_in_natural_order() {
        let red = png(30, 40, [255, 0, 0]);
        let blue = png(30, 40, [0, 0, 255]);
        let bytes = zip_of(&[
            ("vol/", b""),
            ("vol/10.png", &blue),
            ("vol/2.png", &red),
            ("vol/ComicInfo.xml", b"<ComicInfo/>"),
        ]);
        let t = run(bytes, 256).unwrap();
        assert_eq!((t.width, t.height), (30, 40));
        assert_eq!(first_pixel_rgb(&t), [255, 0, 0]);
    }

    #[test]
    fn cbz_skips_a_broken_first_page() {
        let green = png(8, 8, [0, 255, 0]);
        let bytes = zip_of(&[("01.jpg", b"\xFF\xD8broken"), ("02.png", &green)]);
        assert_eq!(first_pixel_rgb(&run(bytes, 256).unwrap()), [0, 255, 0]);
    }

    fn epub(opf: &str, extra: &[(&str, &[u8])]) -> Vec<u8> {
        let container = br#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#;
        let mut entries: Vec<(&str, &[u8])> = vec![
            ("mimetype", b"application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf.as_bytes()),
        ];
        entries.extend_from_slice(extra);
        zip_of(&entries)
    }

    #[test]
    fn epub_uses_declared_cover_not_first_image() {
        let inner = png(10, 10, [0, 0, 255]);
        let cover = png(60, 90, [255, 0, 0]);
        let opf = r#"<package><manifest>
<item id="a" href="Images/a.png" media-type="image/png"/>
<item id="c" href="Images/front.png" media-type="image/png" properties="cover-image"/>
</manifest></package>"#;
        let bytes = epub(
            opf,
            &[
                ("OEBPS/Images/a.png", &inner),
                ("OEBPS/Images/front.png", &cover),
            ],
        );
        let t = run(bytes, 30).unwrap();
        assert_eq!((t.width, t.height), (20, 30));
        assert_eq!(first_pixel_rgb(&t), [255, 0, 0]);
    }

    #[test]
    fn epub_cover_page_with_svg_image() {
        let cover = png(12, 16, [0, 255, 0]);
        let opf = r#"<package><manifest>
<item id="cp" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
<item id="z" href="Images/zzz.png" media-type="image/png"/>
</manifest><spine><itemref idref="cp"/></spine></package>"#;
        let page = br#"<html><body><svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/zzz.png"/></svg></body></html>"#;
        let bytes = epub(
            opf,
            &[
                ("OEBPS/Text/cover.xhtml", page),
                ("OEBPS/Images/zzz.png", &cover),
            ],
        );
        assert_eq!(first_pixel_rgb(&run(bytes, 256).unwrap()), [0, 255, 0]);
    }

    #[test]
    fn epub_without_any_metadata_still_finds_an_image() {
        let img = png(5, 5, [9, 9, 9]);
        let bytes = epub("<package/>", &[("OEBPS/x.png", &img)]);
        assert_eq!(first_pixel_rgb(&run(bytes, 256).unwrap()), [9, 9, 9]);
    }

    #[test]
    fn text_only_zip_has_no_cover() {
        let bytes = zip_of(&[("a.txt", b"hello")]);
        assert_eq!(run(bytes, 256), Err(ThumbError::NoCover));
    }

    #[test]
    fn rar_and_pdf_without_backends_report_missing_dependency() {
        assert!(matches!(
            run(b"Rar!\x1A\x07\x01\x00rest".to_vec(), 256),
            Err(ThumbError::MissingDependency(_))
        ));
        assert!(matches!(
            run(b"%PDF-1.7\n".to_vec(), 256),
            Err(ThumbError::MissingDependency(_))
        ));
    }

    #[test]
    fn corrupt_and_unknown_inputs_fail_cleanly() {
        assert!(matches!(
            run(b"PK\x03\x04truncated".to_vec(), 256),
            Err(ThumbError::Corrupt(_))
        ));
        assert_eq!(
            run(b"just text".to_vec(), 256),
            Err(ThumbError::UnknownFormat)
        );
    }
}

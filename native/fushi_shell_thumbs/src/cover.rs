//! 封面选取规则（纯函数，跨平台单测）。
//!
//! * 漫画包（cbz / cbr / cb7）：文件名主干以 `cover` 开头或就是 `front` / `folder` 的图优先，
//!   否则取自然排序（`2.jpg` < `10.jpg`）后的第一张图；跳过 `__MACOSX/`、点文件、非图片。
//! * epub：OPF 的 `properties="cover-image"`（EPUB 3）→ `<meta name="cover">`（EPUB 2）→
//!   `<guide><reference type="cover">` 指向的封面页里的第一张图 → spine 第一页里的第一张图
//!   → id / href 含 `cover` 的图 → manifest 里第一张图。

use std::cmp::Ordering;

use quick_xml::Reader;
use quick_xml::XmlVersion;
use quick_xml::events::{BytesStart, Event};

/// 解码器认得的图片扩展名（与 Cargo.toml 里 `image` 开的特性一致）。
const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "jfif", "png", "webp", "gif", "bmp", "tif", "tiff",
];

/// 文件名（按扩展名）是不是能解的图片。
pub fn is_image_name(name: &str) -> bool {
    let file = name.rsplit(['/', '\\']).next().unwrap_or(name);
    match file.rsplit_once('.') {
        Some((_, ext)) => IMAGE_EXTENSIONS.iter().any(|e| e.eq_ignore_ascii_case(ext)),
        None => false,
    }
}

/// 归档条目是不是该被忽略的杂物（macOS 资源叉、点文件、Thumbs.db 等）。
fn is_junk_entry(name: &str) -> bool {
    name.split(['/', '\\']).any(|part| {
        part.eq_ignore_ascii_case("__MACOSX") || (part.starts_with('.') && part.len() > 1)
    })
}

fn file_stem_lower(name: &str) -> String {
    let file = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let stem = match file.rsplit_once('.') {
        Some((s, _)) => s,
        None => file,
    };
    stem.to_lowercase()
}

fn is_cover_named(name: &str) -> bool {
    let stem = file_stem_lower(name);
    stem.starts_with("cover") || stem == "front" || stem == "folder"
}

/// 自然排序比较：数字段按数值比，其余按不区分大小写的字符比。
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let mut ai = a.chars().peekable();
    let mut bi = b.chars().peekable();
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(ca), Some(cb)) if ca.is_ascii_digit() && cb.is_ascii_digit() => {
                let da = take_digits(&mut ai);
                let db = take_digits(&mut bi);
                let ta = da.trim_start_matches('0');
                let tb = db.trim_start_matches('0');
                let ord = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(ca), Some(cb)) => {
                let la = ca.to_lowercase().next().unwrap_or(ca);
                let lb = cb.to_lowercase().next().unwrap_or(cb);
                // 路径分隔符排在所有字符之前：`a/1.jpg` 先于 `a-b/1.jpg`。
                let ord = match (la == '/' || la == '\\', lb == '/' || lb == '\\') {
                    (true, true) => Ordering::Equal,
                    (true, false) => Ordering::Less,
                    (false, true) => Ordering::Greater,
                    (false, false) => la.cmp(&lb),
                };
                if ord != Ordering::Equal {
                    return ord;
                }
                ai.next();
                bi.next();
            }
        }
    }
}

fn take_digits(it: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut s = String::new();
    while let Some(c) = it.peek().copied() {
        if c.is_ascii_digit() {
            s.push(c);
            it.next();
        } else {
            break;
        }
    }
    s
}

/// 漫画包里可当封面的图按优先级排好的下标（封面名在前，其余按自然排序）。
/// 第一张解不开时调用方顺次试后面的。
pub fn comic_cover_order(names: &[String]) -> Vec<usize> {
    let mut candidates: Vec<usize> = (0..names.len())
        .filter(|&i| is_image_name(&names[i]) && !is_junk_entry(&names[i]))
        .collect();
    candidates.sort_by(|&x, &y| {
        is_cover_named(&names[y])
            .cmp(&is_cover_named(&names[x]))
            .then_with(|| natural_cmp(&names[x], &names[y]))
    });
    candidates
}

/// 从漫画包条目名里挑封面，返回在 `names` 里的下标。
pub fn pick_comic_cover(names: &[String]) -> Option<usize> {
    comic_cover_order(names).first().copied()
}

// ───────────────────────────── epub ─────────────────────────────

fn local_name(raw: &str) -> &str {
    match raw.rsplit_once(':') {
        Some((_, local)) => local,
        None => raw,
    }
}

fn attr(e: &BytesStart<'_>, name: &str) -> Option<String> {
    e.attributes().flatten().find_map(|a| {
        if local_name(a.key.into_inner()).eq_ignore_ascii_case(name) {
            a.normalized_value(XmlVersion::Implicit1_0)
                .ok()
                .map(|v| v.into_owned())
        } else {
            None
        }
    })
}

fn xml_reader(xml: &[u8]) -> Reader<&[u8]> {
    let mut r = Reader::from_reader(xml);
    let cfg = r.config_mut();
    cfg.trim_text(true);
    cfg.check_end_names = false;
    r
}

/// `META-INF/container.xml` 里第一个 `rootfile` 的 `full-path`（OPF 路径）。
pub fn container_rootfile(xml: &[u8]) -> Option<String> {
    let mut r = xml_reader(xml);
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e))
                if local_name(e.name().into_inner()).eq_ignore_ascii_case("rootfile") =>
            {
                if let Some(p) = attr(&e, "full-path") {
                    return Some(p);
                }
            }
            Ok(Event::Eof) | Err(_) => return None,
            _ => {}
        }
    }
}

/// OPF manifest 的一项（`href` 已解析成 zip 内路径）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestItem {
    pub id: String,
    pub path: String,
    pub media_type: String,
    pub properties: String,
}

impl ManifestItem {
    fn is_image(&self) -> bool {
        self.media_type.to_ascii_lowercase().starts_with("image/") || is_image_name(&self.path)
    }
}

/// OPF 里与封面有关的信息。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpfInfo {
    pub manifest: Vec<ManifestItem>,
    pub cover_meta_id: Option<String>,
    pub spine: Vec<String>,
    pub guide_cover_path: Option<String>,
}

/// 解析 OPF；`opf_path` 是它在 zip 内的路径（相对 href 以它所在目录为基准）。
pub fn parse_opf(xml: &[u8], opf_path: &str) -> OpfInfo {
    let mut info = OpfInfo::default();
    let mut r = xml_reader(xml);
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                let name = e.name();
                let ln = local_name(name.into_inner());
                if ln.eq_ignore_ascii_case("item") {
                    if let Some(href) = attr(&e, "href") {
                        info.manifest.push(ManifestItem {
                            id: attr(&e, "id").unwrap_or_default(),
                            path: resolve_href(opf_path, &href),
                            media_type: attr(&e, "media-type").unwrap_or_default(),
                            properties: attr(&e, "properties").unwrap_or_default(),
                        });
                    }
                } else if ln.eq_ignore_ascii_case("meta") {
                    if attr(&e, "name").is_some_and(|n| n.eq_ignore_ascii_case("cover")) {
                        if let Some(c) = attr(&e, "content") {
                            info.cover_meta_id.get_or_insert(c);
                        }
                    }
                } else if ln.eq_ignore_ascii_case("itemref") {
                    if let Some(id) = attr(&e, "idref") {
                        info.spine.push(id);
                    }
                } else if ln.eq_ignore_ascii_case("reference") {
                    let is_cover =
                        attr(&e, "type").is_some_and(|t| t.eq_ignore_ascii_case("cover"));
                    if is_cover {
                        if let Some(href) = attr(&e, "href") {
                            info.guide_cover_path
                                .get_or_insert(resolve_href(opf_path, &href));
                        }
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    info
}

/// 封面候选：直接是图片，或是要再解析一次找 `<img>` 的 XHTML 页。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoverRef {
    Image(String),
    Page(String),
}

/// 按优先级列出 epub 的封面候选（去重）。
pub fn epub_cover_candidates(opf: &OpfInfo) -> Vec<CoverRef> {
    let mut out: Vec<CoverRef> = Vec::new();
    let mut push = |c: CoverRef| {
        if !out.contains(&c) {
            out.push(c);
        }
    };
    for item in &opf.manifest {
        if item
            .properties
            .split_ascii_whitespace()
            .any(|p| p == "cover-image")
        {
            push(CoverRef::Image(item.path.clone()));
        }
    }
    if let Some(id) = &opf.cover_meta_id {
        // 有的书把 meta 的 content 写成 href 而不是 id。
        if let Some(item) = opf
            .manifest
            .iter()
            .find(|i| &i.id == id || i.path.ends_with(id.as_str()))
        {
            if item.is_image() {
                push(CoverRef::Image(item.path.clone()));
            } else {
                push(CoverRef::Page(item.path.clone()));
            }
        }
    }
    if let Some(page) = &opf.guide_cover_path {
        if is_image_name(page) {
            push(CoverRef::Image(page.clone()));
        } else {
            push(CoverRef::Page(page.clone()));
        }
    }
    if let Some(first) = opf
        .spine
        .first()
        .and_then(|id| opf.manifest.iter().find(|i| &i.id == id))
    {
        push(CoverRef::Page(first.path.clone()));
    }
    for item in &opf.manifest {
        if item.is_image()
            && (item.id.to_lowercase().contains("cover")
                || file_stem_lower(&item.path).contains("cover"))
        {
            push(CoverRef::Image(item.path.clone()));
        }
    }
    if let Some(item) = opf.manifest.iter().find(|i| i.is_image()) {
        push(CoverRef::Image(item.path.clone()));
    }
    out
}

/// XHTML / SVG 页面里第一张图（`<img src>` 或 SVG `<image xlink:href>`），解析成 zip 内路径。
pub fn first_image_in_page(xml: &[u8], page_path: &str) -> Option<String> {
    let mut r = xml_reader(xml);
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                let name = e.name();
                let ln = local_name(name.into_inner());
                let href = if ln.eq_ignore_ascii_case("img") {
                    attr(&e, "src")
                } else if ln.eq_ignore_ascii_case("image") {
                    attr(&e, "href")
                } else {
                    None
                };
                if let Some(h) = href {
                    if !h.starts_with("data:") {
                        return Some(resolve_href(page_path, &h));
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => return None,
            _ => {}
        }
    }
}

/// 把相对 `base_file` 的 href 解析成 zip 内的规范路径（去片段、百分号解码、处理 `.` / `..`）。
pub fn resolve_href(base_file: &str, href: &str) -> String {
    let href = href.split('#').next().unwrap_or("");
    let href = percent_decode(href);
    let mut parts: Vec<&str> = Vec::new();
    if !href.starts_with('/') {
        if let Some((dir, _)) = base_file.rsplit_once('/') {
            parts.extend(dir.split('/').filter(|p| !p.is_empty()));
        }
    }
    for seg in href.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn natural_order_compares_numbers_by_value() {
        let mut v = names(&["10.jpg", "2.jpg", "1.jpg", "001a.jpg"]);
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, names(&["1.jpg", "001a.jpg", "2.jpg", "10.jpg"]));
        assert_eq!(natural_cmp("Page", "page"), "Page".cmp("page"));
        assert_eq!(natural_cmp("a/1.jpg", "a-b/1.jpg"), Ordering::Less);
    }

    #[test]
    fn comic_cover_prefers_first_page_by_natural_order() {
        let v = names(&[
            "vol1/page10.jpg",
            "vol1/page2.png",
            "vol1/ComicInfo.xml",
            "vol1/",
        ]);
        assert_eq!(pick_comic_cover(&v), Some(1));
    }

    #[test]
    fn comic_cover_prefers_cover_named_image_and_skips_junk() {
        let v = names(&[
            "__MACOSX/vol/._cover.jpg",
            "vol/.hidden.jpg",
            "vol/001.jpg",
            "vol/Cover.JPG",
        ]);
        assert_eq!(pick_comic_cover(&v), Some(3));
    }

    #[test]
    fn comic_without_images_has_no_cover() {
        assert_eq!(pick_comic_cover(&names(&["a.txt", "b.xml"])), None);
        assert_eq!(pick_comic_cover(&[]), None);
    }

    #[test]
    fn image_name_detection_is_case_insensitive() {
        assert!(is_image_name("a/B.JPEG"));
        assert!(is_image_name("x.webp"));
        assert!(!is_image_name("x.xhtml"));
        assert!(!is_image_name("jpg"));
    }

    #[test]
    fn resolves_relative_and_encoded_hrefs() {
        assert_eq!(
            resolve_href("OEBPS/content.opf", "Images/cover%20art.jpg"),
            "OEBPS/Images/cover art.jpg"
        );
        assert_eq!(
            resolve_href("OEBPS/Text/p1.xhtml", "../Images/c.png#frag"),
            "OEBPS/Images/c.png"
        );
        assert_eq!(resolve_href("content.opf", "./a.jpg"), "a.jpg");
        assert_eq!(resolve_href("x/y.opf", "/root.jpg"), "root.jpg");
        assert_eq!(resolve_href("x/y.opf", "100%"), "x/100%");
    }

    #[test]
    fn container_xml_yields_rootfile() {
        let xml = br#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#;
        assert_eq!(
            container_rootfile(xml).as_deref(),
            Some("OEBPS/content.opf")
        );
        assert_eq!(container_rootfile(b"<container/>"), None);
    }

    const OPF3: &[u8] = br#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata><meta name="cover" content="wrong"/></metadata>
  <manifest>
    <item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
    <item id="img1" href="Images/inner.jpg" media-type="image/jpeg"/>
    <item id="ci" href="Images/front.jpg" media-type="image/jpeg" properties="cover-image"/>
  </manifest>
  <spine><itemref idref="p1"/></spine>
</package>"#;

    #[test]
    fn epub3_cover_image_property_wins() {
        let opf = parse_opf(OPF3, "OEBPS/content.opf");
        let c = epub_cover_candidates(&opf);
        assert_eq!(c[0], CoverRef::Image("OEBPS/Images/front.jpg".into()));
        assert!(c.contains(&CoverRef::Page("OEBPS/Text/p1.xhtml".into())));
    }

    #[test]
    fn epub2_meta_cover_and_prefixed_namespaces() {
        let xml = br#"<opf:package xmlns:opf="http://www.idpf.org/2007/opf">
  <opf:metadata><opf:meta name="cover" content="my-cover"/></opf:metadata>
  <opf:manifest>
    <opf:item id="a" href="a.png" media-type="image/png"/>
    <opf:item id="my-cover" href="pics/c.jpg" media-type="image/jpeg"/>
  </opf:manifest>
  <opf:guide><opf:reference type="cover" href="cover.xhtml"/></opf:guide>
</opf:package>"#;
        let opf = parse_opf(xml, "content.opf");
        let c = epub_cover_candidates(&opf);
        assert_eq!(c[0], CoverRef::Image("pics/c.jpg".into()));
        assert_eq!(c[1], CoverRef::Page("cover.xhtml".into()));
        assert_eq!(c.last(), Some(&CoverRef::Image("a.png".into())));
    }

    #[test]
    fn epub_without_metadata_falls_back_to_first_spine_page_then_images() {
        let xml = br#"<package><manifest>
  <item id="t" href="t.xhtml" media-type="application/xhtml+xml"/>
  <item id="i" href="i.gif" media-type="image/gif"/>
</manifest><spine><itemref idref="t"/></spine></package>"#;
        let c = epub_cover_candidates(&parse_opf(xml, "content.opf"));
        assert_eq!(
            c,
            vec![
                CoverRef::Page("t.xhtml".into()),
                CoverRef::Image("i.gif".into())
            ]
        );
    }

    #[test]
    fn finds_img_and_svg_image_in_cover_pages() {
        let xhtml = br#"<html xmlns="http://www.w3.org/1999/xhtml"><body>
<div><img src="data:image/png;base64,AAAA"/><img alt="c" src="../Images/cover.jpg"/></div></body></html>"#;
        assert_eq!(
            first_image_in_page(xhtml, "OEBPS/Text/cover.xhtml").as_deref(),
            Some("OEBPS/Images/cover.jpg")
        );
        let svg = br#"<html><body><svg xmlns:xlink="http://www.w3.org/1999/xlink">
<image width="600" height="800" xlink:href="img/c.png"/></svg></body></html>"#;
        assert_eq!(
            first_image_in_page(svg, "cover.xhtml").as_deref(),
            Some("img/c.png")
        );
        assert_eq!(first_image_in_page(b"<html><p>no</p></html>", "a"), None);
    }
}

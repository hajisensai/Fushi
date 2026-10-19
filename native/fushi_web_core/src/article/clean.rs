//! 正文 DOM → 规整的 XHTML 片段（`<section>` 内部，直接进 EPUB 章节文件）。
//!
//! 只留阅读需要的结构：段落、空行、标题、ruby 注音（`ruby/rb/rt/rp/rtc`）、强调类行内标签、
//! 图片；其余标签拆壳保留文字（`span` / `a` / `font`…），脚本 / 表单 / 广告位整棵丢掉。
//! `<br>` 分隔的纯文本（中文站常见的 `文字<br><br>文字`）切成段落。
//!
//! 输出是合法 XHTML：自闭合 `<br/>` / `<img/>`，文本按 XML 转义，非 ASCII 字符原样（UTF-8）。
//! 图片的 `src` 写成占位 `fushi-web-image:<序号>`，绝对 URL 列在 [`Cleaned::images`]：
//! 取图（联网、带 cookie / Referer、全局代理）在 Dart，取回后按序号替换文件名。

use std::collections::HashMap;

use dom_query::{Matcher, NodeRef};
use url::Url;

/// 图片占位 src 的前缀（Dart 侧按它替换成 EPUB 内的文件名）。
pub const IMAGE_PLACEHOLDER_PREFIX: &str = "fushi-web-image:";

/// 连续空行最多保留这么多（作者用空行控节奏，但广告位拆空后会留下成串空段）。
const MAX_BLANK_RUN: usize = 2;

/// 整棵丢掉的标签。
const DROP_TAGS: &[&str] = &[
    "script", "style", "noscript", "iframe", "frame", "frameset", "form", "input", "button",
    "select", "option", "textarea", "nav", "aside", "footer", "svg", "canvas", "video", "audio",
    "object", "embed", "template", "head", "title", "meta", "link", "dialog", "menu", "map",
];

/// 块级：前后断段。
const BLOCK_TAGS: &[&str] = &[
    "p",
    "div",
    "section",
    "article",
    "main",
    "blockquote",
    "li",
    "ul",
    "ol",
    "dl",
    "dd",
    "dt",
    "table",
    "tbody",
    "thead",
    "tfoot",
    "tr",
    "td",
    "th",
    "center",
    "figure",
    "figcaption",
    "header",
    "address",
    "details",
    "summary",
    "body",
    "html",
    "pre",
];

/// 原样保留的行内标签（输出同名）。
const KEEP_INLINE: &[&str] = &[
    "ruby", "rb", "rt", "rp", "rtc", "em", "strong", "b", "i", "u", "s", "sub", "sup", "small",
    "mark", "q", "cite", "del",
];

/// 通用模式下按 class / id 判为噪声的关键词（站点规则模式不用：规则自己给 remove）。
const NOISE_HINTS: &[&str] = &[
    "advert",
    "adsbygoogle",
    "ad-",
    "ads-",
    "-ad",
    "_ad",
    "banner",
    "sponsor",
    "comment",
    "share",
    "social",
    "recommend",
    "related",
    "footer",
    "sidebar",
    "breadcrumb",
    "pager",
    "pagination",
    "toolbar",
    "bookmark",
    "report",
];

#[derive(Debug)]
enum Block {
    Para(String),
    Heading(u8, String),
    Blank,
}

/// 清洗结果。
pub(crate) struct Cleaned {
    pub xhtml: String,
    pub images: Vec<String>,
    pub paragraphs: u32,
    /// 可见字数（不含注音 rt / rp，不含空白）。
    pub chars: u32,
    /// 第一段正文（纯文本，≤ 160 字）。
    pub excerpt: String,
    /// 全部可见文字（去重用的内容指纹从它算）。
    pub text: String,
}

pub(crate) struct Cleaner<'a> {
    base: Option<&'a Url>,
    remove: Option<&'a Matcher>,
    /// 通用模式：按 class / id 关键词剔噪声。
    drop_noise: bool,
    blocks: Vec<Block>,
    para: String,
    para_visible: usize,
    para_has_image: bool,
    open_inline: Vec<&'static str>,
    heading: Option<u8>,
    br_run: usize,
    annotation_depth: usize,
    pre_depth: usize,
    images: Vec<String>,
    image_index: HashMap<String, usize>,
    chars: usize,
    text: String,
    /// 当前段的可见文字（出段时判是否站点垃圾行，再并进 [`Self::text`]）。
    para_text: String,
}

impl<'a> Cleaner<'a> {
    pub(crate) fn new(
        base: Option<&'a Url>,
        remove: Option<&'a Matcher>,
        drop_noise: bool,
    ) -> Self {
        Self {
            base,
            remove,
            drop_noise,
            blocks: Vec::new(),
            para: String::new(),
            para_visible: 0,
            para_has_image: false,
            open_inline: Vec::new(),
            heading: None,
            br_run: 0,
            annotation_depth: 0,
            pre_depth: 0,
            images: Vec::new(),
            image_index: HashMap::new(),
            chars: 0,
            text: String::new(),
            para_text: String::new(),
        }
    }

    /// 喂一个正文根（多个根按调用顺序拼接）。
    pub(crate) fn feed(&mut self, root: &NodeRef) {
        self.walk_children(root);
        self.flush();
    }

    pub(crate) fn finish(mut self) -> Cleaned {
        self.flush();
        // 首尾空行去掉，连续空行压到 MAX_BLANK_RUN。
        while matches!(self.blocks.first(), Some(Block::Blank)) {
            self.blocks.remove(0);
        }
        while matches!(self.blocks.last(), Some(Block::Blank)) {
            self.blocks.pop();
        }
        let mut xhtml = String::with_capacity(self.text.len() * 2);
        let mut paragraphs = 0u32;
        let mut excerpt = String::new();
        let mut blank_run = 0usize;
        for block in &self.blocks {
            match block {
                Block::Blank => {
                    blank_run += 1;
                    if blank_run <= MAX_BLANK_RUN {
                        xhtml.push_str("<p><br/></p>\n");
                    }
                }
                Block::Para(body) => {
                    blank_run = 0;
                    paragraphs += 1;
                    xhtml.push_str("<p>");
                    xhtml.push_str(body);
                    xhtml.push_str("</p>\n");
                    if excerpt.is_empty() {
                        excerpt = excerpt_of(body);
                    }
                }
                Block::Heading(level, body) => {
                    blank_run = 0;
                    xhtml.push_str(&format!("<h{level}>{body}</h{level}>\n"));
                }
            }
        }
        Cleaned {
            xhtml,
            images: self.images,
            paragraphs,
            chars: self.chars as u32,
            excerpt,
            text: self.text,
        }
    }

    fn walk_children(&mut self, node: &NodeRef) {
        let mut child = node.first_child();
        while let Some(c) = child {
            self.walk(&c);
            child = c.next_sibling();
        }
    }

    fn walk(&mut self, node: &NodeRef) {
        if node.is_text() {
            self.push_text(&node.text());
            return;
        }
        if !node.is_element() {
            return;
        }
        let Some(name) = node.node_name() else { return };
        let name = name.to_ascii_lowercase();
        if DROP_TAGS.contains(&name.as_str()) || self.is_removed(node) {
            return;
        }
        match name.as_str() {
            "br" => self.on_br(),
            "hr" => {
                self.flush();
                self.blocks.push(Block::Blank);
            }
            "img" => self.push_image(node),
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                self.flush();
                let level = name.as_bytes()[1] - b'0';
                self.heading = Some(level.clamp(2, 6));
                self.walk_children(node);
                self.flush();
                self.heading = None;
            }
            tag if BLOCK_TAGS.contains(&tag) => {
                self.flush();
                let blocks_before = self.blocks.len();
                if tag == "pre" {
                    self.pre_depth += 1;
                }
                self.walk_children(node);
                if tag == "pre" {
                    self.pre_depth -= 1;
                }
                let produced = self.para_visible > 0 || self.para_has_image;
                self.flush();
                // 空 <p>（`<p><br/></p>` / `<p>　</p>`）是作者的空行。
                if tag == "p" && !produced && self.blocks.len() == blocks_before {
                    self.blocks.push(Block::Blank);
                }
            }
            tag => {
                if let Some(keep) = KEEP_INLINE.iter().find(|k| **k == tag) {
                    self.open_tag(keep);
                    let annotation = matches!(*keep, "rt" | "rp");
                    if annotation {
                        self.annotation_depth += 1;
                    }
                    self.walk_children(node);
                    if annotation {
                        self.annotation_depth -= 1;
                    }
                    self.close_tag(keep);
                } else {
                    // span / a / font / label… 拆壳。
                    self.walk_children(node);
                }
            }
        }
    }

    fn is_removed(&self, node: &NodeRef) -> bool {
        if let Some(matcher) = self.remove {
            if node.is_match(matcher) {
                return true;
            }
        }
        if node.has_attr("hidden") || node.attr("aria-hidden").is_some_and(|v| &*v == "true") {
            return true;
        }
        if let Some(style) = node.attr("style") {
            let compact: String = style
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect::<String>()
                .to_ascii_lowercase();
            if compact.contains("display:none") || compact.contains("visibility:hidden") {
                return true;
            }
        }
        if self.drop_noise {
            let class = node
                .attr("class")
                .map(|c| c.to_ascii_lowercase())
                .unwrap_or_default();
            let id = node
                .attr("id")
                .map(|c| c.to_ascii_lowercase())
                .unwrap_or_default();
            let hay = format!(" {class} {id} ");
            if hay.split_whitespace().any(|token| {
                token == "ad"
                    || token == "ads"
                    || NOISE_HINTS.iter().any(|hint| token.contains(hint))
            }) {
                return true;
            }
        }
        false
    }

    fn open_tag(&mut self, tag: &'static str) {
        self.para.push('<');
        self.para.push_str(tag);
        self.para.push('>');
        self.open_inline.push(tag);
    }

    fn close_tag(&mut self, tag: &'static str) {
        // 段落在这个标签里被 <br> 切过时，栈里可能已经没有它了（flush 关掉了）。
        if let Some(pos) = self.open_inline.iter().rposition(|t| *t == tag) {
            for t in self.open_inline.drain(pos..).rev() {
                self.para.push_str("</");
                self.para.push_str(t);
                self.para.push('>');
            }
        }
    }

    fn push_text(&mut self, raw: &str) {
        let mut pending_space = false;
        for c in raw.chars() {
            let is_line_break = c == '\n' || c == '\r';
            if self.pre_depth > 0 && c == '\n' {
                self.on_br();
                continue;
            }
            // 只折叠 ASCII 空白；全角空格（日文段首缩进）与 NBSP 原样保留。
            if c.is_ascii_whitespace() || is_line_break {
                pending_space = true;
                continue;
            }
            if c.is_control() || c == '\u{FEFF}' || c == '\u{200B}' {
                continue;
            }
            if pending_space && (self.para_visible > 0 || self.para_has_image) {
                self.para.push(' ');
            }
            pending_space = false;
            self.br_run = 0;
            match c {
                '&' => self.para.push_str("&amp;"),
                '<' => self.para.push_str("&lt;"),
                '>' => self.para.push_str("&gt;"),
                _ => self.para.push(c),
            }
            if self.annotation_depth == 0 {
                self.para_visible += 1;
                self.para_text.push(c);
            }
        }
        if pending_space
            && (self.para_visible > 0 || self.para_has_image)
            && !self.para.ends_with(' ')
        {
            self.para.push(' ');
        }
    }

    fn on_br(&mut self) {
        if self.annotation_depth > 0 {
            return;
        }
        if self.para_visible > 0 || self.para_has_image {
            self.flush_keep_inline();
            self.br_run = 1;
        } else {
            self.br_run += 1;
            // `文字<br><br>文字` 只是断段；三个及以上才是作者留的空行。
            if self.br_run == 3 {
                self.blocks.push(Block::Blank);
            }
        }
    }

    fn push_image(&mut self, node: &NodeRef) {
        let src = ["data-src", "data-original", "data-lazy-src", "src"]
            .iter()
            .find_map(|attr| {
                node.attr(attr)
                    .map(|v| v.trim().to_owned())
                    .filter(|v| !v.is_empty())
            });
        let Some(src) = src else { return };
        if src.starts_with("data:") || src.starts_with("javascript:") {
            return;
        }
        let tiny = |attr: &str| {
            node.attr(attr)
                .and_then(|v| v.trim().trim_end_matches("px").parse::<u32>().ok())
                .is_some_and(|v| v <= 2)
        };
        if tiny("width") || tiny("height") {
            return; // 计数像素 / 间隔图。
        }
        let absolute = match self.base {
            Some(base) => match base.join(&src) {
                Ok(u) if u.scheme() == "http" || u.scheme() == "https" => u.to_string(),
                _ => return,
            },
            None => match Url::parse(&src) {
                Ok(u) if u.scheme() == "http" || u.scheme() == "https" => u.to_string(),
                _ => return,
            },
        };
        let index = match self.image_index.get(&absolute) {
            Some(i) => *i,
            None => {
                let i = self.images.len();
                self.images.push(absolute.clone());
                self.image_index.insert(absolute, i);
                i
            }
        };
        let alt = node
            .attr("alt")
            .map(|a| escape_attr(&a))
            .unwrap_or_default();
        self.para.push_str(&format!(
            "<img src=\"{IMAGE_PLACEHOLDER_PREFIX}{index}\" alt=\"{alt}\"/>"
        ));
        self.para_has_image = true;
        self.br_run = 0;
    }

    /// 结束当前段（行内标签全部关掉）。
    fn flush(&mut self) {
        for t in self.open_inline.drain(..).rev() {
            self.para.push_str("</");
            self.para.push_str(t);
            self.para.push('>');
        }
        self.emit_para();
    }

    /// `<br>` 断段：关掉打开的行内标签、出段，再在新段里按原顺序重新打开。
    fn flush_keep_inline(&mut self) {
        let open = self.open_inline.clone();
        for t in open.iter().rev() {
            self.para.push_str("</");
            self.para.push_str(t);
            self.para.push('>');
        }
        self.emit_para();
        for t in &open {
            self.para.push('<');
            self.para.push_str(t);
            self.para.push('>');
        }
    }

    fn emit_para(&mut self) {
        let body = std::mem::take(&mut self.para);
        let para_text = std::mem::take(&mut self.para_text);
        let has_content = self.para_visible > 0 || self.para_has_image;
        let has_image = self.para_has_image;
        self.para_visible = 0;
        self.para_has_image = false;
        if !has_content {
            return;
        }
        if self.drop_noise && !has_image && is_junk_line(&para_text) {
            return;
        }
        let body = body.trim_end_matches(' ').to_owned();
        let body = strip_empty_inline(&body);
        self.chars += para_text.chars().filter(|c| !c.is_whitespace()).count();
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        self.text.push_str(para_text.trim());
        match self.heading {
            Some(level) => self.blocks.push(Block::Heading(level, body)),
            None => self.blocks.push(Block::Para(body)),
        }
    }
}

/// 通用模式下整段丢掉的站点垃圾行：短（≤ 40 字）且含这些词（盗版站的域名提示、
/// 「加入书签」、分页提示……）。站点规则模式不用它：规则自己给 remove。
const JUNK_PHRASES: &[&str] = &[
    "最新域名",
    "请收藏",
    "加入书签",
    "手机阅读",
    "天才一秒记住",
    "本章未完",
    "点击下一页",
    "笔趣阁",
    "最快更新",
    "无弹窗",
    "免费阅读",
    "章节错误",
    "抢先阅读",
    "插入书签",
];

fn is_junk_line(text: &str) -> bool {
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    compact.chars().count() <= 40 && JUNK_PHRASES.iter().any(|p| compact.contains(p))
}

/// 断段后重新打开又立即关掉的空行内标签（`<em></em>`）去掉。
fn strip_empty_inline(body: &str) -> String {
    let mut out = body.to_owned();
    loop {
        let before = out.len();
        for tag in KEEP_INLINE {
            let empty = format!("<{tag}></{tag}>");
            out = out.replace(&empty, "");
        }
        if out.len() == before {
            return out;
        }
    }
}

fn escape_attr(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// 段落 XHTML → 纯文本摘要（去标签、去注音）。
fn excerpt_of(body: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    let mut tag = String::new();
    let mut annotation = 0usize;
    for c in body.chars() {
        if in_tag {
            if c == '>' {
                in_tag = false;
                let t = tag.trim_end_matches('/');
                match t {
                    "rt" | "rp" => annotation += 1,
                    "/rt" | "/rp" => annotation = annotation.saturating_sub(1),
                    _ => {}
                }
                tag.clear();
            } else {
                tag.push(c);
            }
            continue;
        }
        if c == '<' {
            in_tag = true;
            continue;
        }
        if annotation == 0 {
            out.push(c);
        }
    }
    let out = out
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&");
    let trimmed = out.trim();
    trimmed.chars().take(160).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use dom_query::Document;

    fn clean(html: &str) -> Cleaned {
        let doc = Document::from(html);
        let mut cleaner = Cleaner::new(None, None, false);
        cleaner.feed(&doc.select("body").nodes()[0]);
        cleaner.finish()
    }

    #[test]
    fn br_separated_text_becomes_paragraphs() {
        let c = clean(
            "<body>　　夕阳西下。<br><br>　　何以琛站在窗前。<br/><br/><br/><br/>也许。</body>",
        );
        assert_eq!(
            c.xhtml,
            "<p>　　夕阳西下。</p>\n<p>　　何以琛站在窗前。</p>\n<p><br/></p>\n<p>也许。</p>\n"
        );
        assert_eq!(c.paragraphs, 3);
    }

    #[test]
    fn ruby_is_kept_and_not_counted() {
        let c = clean(
            "<body><p>彼女は<ruby>御神体<rp>(</rp><rt>パンツ</rt><rp>)</rp></ruby>を。</p></body>",
        );
        assert_eq!(
            c.xhtml,
            "<p>彼女は<ruby>御神体<rp>(</rp><rt>パンツ</rt><rp>)</rp></ruby>を。</p>\n"
        );
        assert_eq!(c.chars, 8); // 彼女は + 御神体 + を。（rt / rp 不计）
        assert_eq!(c.excerpt, "彼女は御神体を。");
    }

    #[test]
    fn blank_paragraphs_are_kept_but_capped() {
        let c = clean(
            "<body><p>一</p><p><br></p><p><br></p><p><br></p><p><br></p><p>二</p><p><br></p></body>",
        );
        assert_eq!(
            c.xhtml,
            "<p>一</p>\n<p><br/></p>\n<p><br/></p>\n<p>二</p>\n"
        );
    }

    #[test]
    fn scripts_and_hidden_are_dropped_and_text_escaped() {
        let c = clean(
            "<body><p>a &lt; b &amp; c</p><script>evil()</script><div style='display: none'>x</div></body>",
        );
        assert_eq!(c.xhtml, "<p>a &lt; b &amp; c</p>\n");
    }

    #[test]
    fn inline_tags_survive_br_split() {
        let c = clean("<body><p><em>一<br>二</em></p></body>");
        assert_eq!(c.xhtml, "<p><em>一</em></p>\n<p><em>二</em></p>\n");
    }

    #[test]
    fn images_become_placeholders_with_absolute_urls() {
        let doc = Document::from(
            "<body><p>前</p><img data-src='/i/1.jpg' src='data:image/gif;base64,AA' alt='挿絵'><img src='/pixel.gif' width='1'></body>",
        );
        let base = Url::parse("https://example.com/novel/1/").unwrap();
        let mut cleaner = Cleaner::new(Some(&base), None, false);
        cleaner.feed(&doc.select("body").nodes()[0]);
        let c = cleaner.finish();
        assert_eq!(c.images, vec!["https://example.com/i/1.jpg".to_owned()]);
        assert!(c
            .xhtml
            .contains("<img src=\"fushi-web-image:0\" alt=\"挿絵\"/>"));
    }
}

//! `ffc_parse_epub_*`：EPUB 章节 XHTML 的 DOM 派生量（纯文本 / 字数 / ruby 读音轨 /
//! 目录锚点偏移 / 插图索引 / 图片引用）。
//!
//! 取代 `packages/fushi_engine/lib/epub/epub_book.dart` 里基于 `package:html` 的实现
//! （那份已删除，这里是唯一实现）。结果必须与旧实现**逐码元一致**：学习统计、阅读位置、
//! 有声书 cue 偏移都建立在这些数上。为此：
//!
//! - HTML5 树构建用 html5ever（与 `package:html` 同为 WHATWG 解析算法）；解析后先拍平成
//!   [Tree]，把 `package:html`（html5lib 移植，没有 template 支持）与 html5ever 的结构差异
//!   抹平：`<template>` 的内容当作它的普通子节点；不丢弃开头的 U+FEFF。
//! - 属性的迭代顺序复刻 `package:html`：它在外来内容（SVG / MathML）里调整过名字的属性
//!   （`xlink:href` 等带命名空间的）会被挪到属性表末尾。
//! - 空白判定分两套：`\s` 正则（JS 语义）与 `String.trim()`（多一个 U+0085），见
//!   [is_regex_space] / [is_trim_space]。
//! - 偏移全部以 UTF-16 码元计（Dart `String.length`），字数用 [super::StudyCharState]。
//!
//! 调用方先在 Dart 侧做 `normalizeSelfClosingRawTextTags`（与其它 DOM 消费者共用的
//! 预处理），再把 UTF-8 交进来。

use std::collections::HashMap;
use std::sync::OnceLock;

use html5ever::tendril::TendrilSink;
use html5ever::tokenizer::TokenizerOpts;
use html5ever::{parse_document, ParseOpts};
use markup5ever_rcdom::{Handle, NodeData, RcDom};
use regex::Regex;

use super::StudyCharState;
use crate::{guard, status};

// ---------------------------------------------------------------------------
// 拍平的文档树
// ---------------------------------------------------------------------------

enum Kind {
    Document,
    Element {
        /// 原样的 local name（`package:html` 的 `localName`）。
        name: String,
        /// （属性名字符串，是否带命名空间，值）：按 `package:html` 的迭代顺序排好。
        attrs: Vec<(String, bool, String)>,
    },
    Text(Vec<u16>),
    Other,
}

struct Node {
    kind: Kind,
    parent: Option<usize>,
    children: Vec<usize>,
}

struct Tree {
    nodes: Vec<Node>,
}

impl Tree {
    fn parse(html: &str) -> Tree {
        let opts = ParseOpts {
            tokenizer: TokenizerOpts {
                discard_bom: false,
                ..Default::default()
            },
            ..Default::default()
        };
        let dom = parse_document(RcDom::default(), opts).one(html);
        let mut tree = Tree { nodes: Vec::new() };
        tree.add(&dom.document, None);
        tree
    }

    fn add(&mut self, handle: &Handle, parent: Option<usize>) -> usize {
        let index = self.nodes.len();
        let mut child_handles: Vec<Handle> = handle.children.borrow().clone();
        let kind = match &handle.data {
            NodeData::Document => Kind::Document,
            NodeData::Text { contents } => Kind::Text(contents.borrow().encode_utf16().collect()),
            NodeData::Element {
                name,
                attrs,
                template_contents,
                ..
            } => {
                if let Some(contents) = template_contents.borrow().as_ref() {
                    // package:html 没有 template 内容文档：内容就是普通子节点。
                    child_handles.extend(contents.children.borrow().iter().cloned());
                }
                let attrs = attrs.borrow();
                let mut plain = Vec::new();
                let mut namespaced = Vec::new();
                for a in attrs.iter() {
                    let has_ns = !a.name.ns.is_empty();
                    let local: &str = &a.name.local;
                    let label = match &a.name.prefix {
                        Some(prefix) => format!("{}:{}", &**prefix, local),
                        None => local.to_string(),
                    };
                    let entry = (label, has_ns, a.value.to_string());
                    if has_ns {
                        namespaced.push(entry);
                    } else {
                        plain.push(entry);
                    }
                }
                plain.extend(namespaced);
                Kind::Element {
                    name: name.local.to_string(),
                    attrs: plain,
                }
            }
            _ => Kind::Other,
        };
        self.nodes.push(Node {
            kind,
            parent,
            children: Vec::new(),
        });
        for child in child_handles.iter() {
            let c = self.add(child, Some(index));
            self.nodes[index].children.push(c);
        }
        index
    }

    fn name(&self, i: usize) -> Option<&str> {
        match &self.nodes[i].kind {
            Kind::Element { name, .. } => Some(name),
            _ => None,
        }
    }

    fn is_element(&self, i: usize) -> bool {
        matches!(self.nodes[i].kind, Kind::Element { .. })
    }

    /// `element.attributes['x']`：只认不带命名空间的属性名。
    fn attr(&self, i: usize, key: &str) -> Option<&str> {
        match &self.nodes[i].kind {
            Kind::Element { attrs, .. } => attrs
                .iter()
                .find(|(name, has_ns, _)| !*has_ns && name == key)
                .map(|(_, _, v)| v.as_str()),
            _ => None,
        }
    }

    fn id(&self, i: usize) -> &str {
        self.attr(i, "id").unwrap_or("")
    }

    /// 文档序（先序）里第一个 local name 为 [name] 的**后代**元素。
    fn first_descendant(&self, root: usize, name: &str) -> Option<usize> {
        let mut stack: Vec<usize> = self.nodes[root].children.iter().rev().copied().collect();
        while let Some(i) = stack.pop() {
            if self.name(i) == Some(name) {
                return Some(i);
            }
            stack.extend(self.nodes[i].children.iter().rev().copied());
        }
        None
    }

    /// 先序遍历 [root] 的全部后代元素（不含 root）。
    fn descendants(&self, root: usize) -> Vec<usize> {
        let mut out = Vec::new();
        let mut stack: Vec<usize> = self.nodes[root].children.iter().rev().copied().collect();
        while let Some(i) = stack.pop() {
            if self.is_element(i) {
                out.push(i);
            }
            stack.extend(self.nodes[i].children.iter().rev().copied());
        }
        out
    }

    /// `document.body`：`documentElement?.querySelector('body')`。
    fn body(&self) -> Option<usize> {
        let html = self.first_descendant(0, "html")?;
        self.first_descendant(html, "body")
    }

    /// `Element.text`：按文档序拼接全部后代文本节点。
    fn text_of(&self, i: usize, out: &mut Vec<u16>) {
        if let Kind::Text(t) = &self.nodes[i].kind {
            out.extend_from_slice(t);
            return;
        }
        for &c in &self.nodes[i].children {
            self.text_of(c, out);
        }
    }
}

// ---------------------------------------------------------------------------
// Dart 语义的小工具
// ---------------------------------------------------------------------------

/// JS / Dart 正则 `\s`（非 unicode 模式，逐码元）。
fn is_regex_space(u: u16) -> bool {
    matches!(
        u,
        0x09..=0x0D
            | 0x20
            | 0xA0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
            | 0xFEFF
    )
}

/// Dart `String.trim()` 的空白（比 `\s` 多 U+0085）。
fn is_trim_space(u: u16) -> bool {
    u == 0x85 || is_regex_space(u)
}

fn trim_range(s: &[u16]) -> (usize, usize) {
    let mut start = 0;
    let mut end = s.len();
    while start < end && is_trim_space(s[start]) {
        start += 1;
    }
    while end > start && is_trim_space(s[end - 1]) {
        end -= 1;
    }
    (start, end)
}

fn trim(s: &[u16]) -> &[u16] {
    let (a, b) = trim_range(s);
    &s[a..b]
}

/// `localName.toLowerCase()`（只用于与 ASCII 标签名比较）。
fn lower(name: &str) -> String {
    if name.is_ascii() {
        name.to_ascii_lowercase()
    } else {
        name.to_lowercase()
    }
}

fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn is_ruby_annotation(tag: &str) -> bool {
    tag == "rt" || tag == "rp" || tag == "rtc"
}

/// `EpubBook.backgroundImageUrlPattern`：
/// `background(?:-image)?\s*:[^;}]*url\(\s*['"]?([^'")]+?)['"]?\s*\)`，大小写不敏感
/// （JS 非 unicode 模式只折叠 ASCII 字母），`\s` 用 JS 的空白集合。
fn background_url_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        const S: &str = r"[\t\n\x0B\x0C\r \u{A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}]";
        let pattern = format!(
            r#"(?i-u:background)(?:(?i-u:-image))?{S}*:[^;}}]*(?i-u:url)\({S}*['"]?([^'")]+?)['"]?{S}*\)"#
        );
        Regex::new(&pattern).expect("background url pattern")
    })
}

fn push_background_urls(css: &str, refs: &mut Vec<Vec<u16>>) {
    for caps in background_url_pattern().captures_iter(css) {
        let raw = utf16(caps.get(1).map(|m| m.as_str()).unwrap_or(""));
        let r = trim(&raw);
        if !r.is_empty() {
            refs.push(r.to_vec());
        }
    }
}

// ---------------------------------------------------------------------------
// 纯文本 + ruby 读音轨（原 _RubyPlainTextWalker；chapterPlainText 即其 text）
// ---------------------------------------------------------------------------

const BLOCK_TAGS: &[&str] = &[
    "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "dd", "dt", "pre",
];
const MEDIA_TAGS: &[&str] = &["img", "image", "svg", "video"];
const MAX_SEPARATOR_BLOCK: usize = 64;

/// `^[\s◇◆♢♦◈＊*※・·〇○●◎□■☆★△▲▽▼─━―－\-=＝#＃~〜～†‡§]+$`（逐码元）。
fn separator_only(units: &[u16]) -> bool {
    const SEP: &str = "◇◆♢♦◈＊*※・·〇○●◎□■☆★△▲▽▼─━―－-=＝#＃~〜～†‡§";
    static SET: OnceLock<Vec<u16>> = OnceLock::new();
    let set = SET.get_or_init(|| utf16(SEP));
    !units.is_empty() && units.iter().all(|u| is_regex_space(*u) || set.contains(u))
}

pub struct Ruby {
    pub start: usize,
    pub end: usize,
    pub reading: Vec<u16>,
}

#[derive(Default)]
pub struct PlainText {
    pub text: Vec<u16>,
    pub rubies: Vec<Ruby>,
    pub block_ends: Vec<usize>,
    pub scene_breaks: Vec<usize>,
}

struct Walker<'a> {
    tree: &'a Tree,
    out: Vec<u16>,
    rubies: Vec<Ruby>,
    pending_space: bool,
    ruby_start: i64,
    reading: Option<Vec<u16>>,
    block_ends: Vec<usize>,
    scene_breaks: Vec<usize>,
}

impl<'a> Walker<'a> {
    fn has_media(&self, i: usize) -> bool {
        for &c in &self.tree.nodes[i].children {
            if let Some(name) = self.tree.name(c) {
                if MEDIA_TAGS.contains(&name) || self.has_media(c) {
                    return true;
                }
            }
        }
        false
    }

    fn append(&mut self, data: &[u16]) {
        for &ch in data {
            if is_regex_space(ch) {
                self.pending_space = true;
                continue;
            }
            if self.pending_space {
                if !self.out.is_empty() {
                    self.out.push(0x20);
                }
                self.pending_space = false;
            }
            if self.ruby_start == -1 {
                self.ruby_start = self.out.len() as i64;
            }
            self.out.push(ch);
        }
    }

    fn close_block(&mut self, node: usize, tag: &str, start: usize) {
        let end = self.out.len();
        self.block_ends.push(end);
        if end == start {
            if tag == "p" && !self.has_media(node) {
                self.scene_breaks.push(end);
            }
        } else if end - start <= MAX_SEPARATOR_BLOCK && separator_only(&self.out[start..end]) {
            self.scene_breaks.push(end);
        }
    }

    fn visit(&mut self, i: usize) {
        let tree = self.tree;
        match &tree.nodes[i].kind {
            Kind::Text(t) => {
                self.append(t);
                return;
            }
            Kind::Element { .. } => {}
            _ => {
                for &c in &tree.nodes[i].children {
                    self.visit(c);
                }
                return;
            }
        }
        let tag = tree.name(i).unwrap_or("");
        if is_ruby_annotation(tag) {
            if self.reading.is_some() && tag != "rp" {
                let targets: Vec<usize> = if tag == "rt" {
                    vec![i]
                } else {
                    tree.descendants(i)
                        .into_iter()
                        .filter(|&d| tree.name(d) == Some("rt"))
                        .collect()
                };
                let mut buf = Vec::new();
                for rt in targets {
                    tree.text_of(rt, &mut buf);
                }
                self.reading.as_mut().unwrap().extend_from_slice(&buf);
            }
            return;
        }
        if tag == "hr" {
            self.scene_breaks.push(self.out.len());
            return;
        }
        let is_ruby = tag == "ruby" && self.ruby_start == -2;
        if is_ruby {
            self.ruby_start = -1;
            self.reading = Some(Vec::new());
        }
        let is_block = BLOCK_TAGS.contains(&tag);
        let block_start = self.out.len();
        for &c in &tree.nodes[i].children {
            self.visit(c);
        }
        if is_block {
            self.close_block(i, tag, block_start);
        }
        if is_ruby {
            let raw = self.reading.take().unwrap();
            // `replaceAll(RegExp(r'\s+'), '').trim()`
            let squeezed: Vec<u16> = raw.into_iter().filter(|u| !is_regex_space(*u)).collect();
            let reading = trim(&squeezed).to_vec();
            if self.ruby_start >= 0 && !reading.is_empty() {
                self.rubies.push(Ruby {
                    start: self.ruby_start as usize,
                    end: self.out.len(),
                    reading,
                });
            }
            self.ruby_start = -2;
        }
    }
}

fn plain_text(tree: &Tree, body: Option<usize>) -> PlainText {
    let mut w = Walker {
        tree,
        out: Vec::new(),
        rubies: Vec::new(),
        pending_space: false,
        ruby_start: -2,
        reading: None,
        block_ends: Vec::new(),
        scene_breaks: Vec::new(),
    };
    if let Some(b) = body {
        w.visit(b);
    }
    let raw = w.out;
    let (start, end) = trim_range(&raw);
    // shift = raw.length - raw.trimLeft().length；trimLeft 全空白时 start == raw.len()。
    let shift = start;
    let text = raw[start..end].to_vec();
    let len = text.len() as i64;
    let rubies = w
        .rubies
        .into_iter()
        .filter(|r| r.end as i64 - shift as i64 <= len && r.start as i64 - shift as i64 >= 0)
        .map(|r| Ruby {
            start: r.start - shift,
            end: r.end - shift,
            reading: r.reading,
        })
        .collect();
    let clamp = |o: usize| -> usize { (o as i64 - shift as i64).clamp(0, len) as usize };
    PlainText {
        text,
        rubies,
        block_ends: w.block_ends.into_iter().map(clamp).collect(),
        scene_breaks: w.scene_breaks.into_iter().map(clamp).collect(),
    }
}

// ---------------------------------------------------------------------------
// 目录锚点偏移（原 chapterAnchorCharOffsets）
// ---------------------------------------------------------------------------

/// [wanted] 里每个 id（去掉空串、去重后）在章内之前的学习字数；找不到的不出现。
/// 返回 (wanted 下标, 偏移)，按命中顺序。
fn anchor_offsets(tree: &Tree, body: Option<usize>, wanted: &[Vec<u16>]) -> Vec<(usize, u64)> {
    let mut index: HashMap<Vec<u16>, usize> = HashMap::new();
    for (i, id) in wanted.iter().enumerate() {
        if !id.is_empty() {
            index.entry(id.clone()).or_insert(i);
        }
    }
    let mut found: Vec<(usize, u64)> = Vec::new();
    let Some(body) = body else { return found };
    if index.is_empty() {
        return found;
    }
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut state = StudyCharState::default();

    fn visit(
        tree: &Tree,
        i: usize,
        index: &HashMap<Vec<u16>, usize>,
        seen: &mut std::collections::HashSet<usize>,
        found: &mut Vec<(usize, u64)>,
        state: &mut StudyCharState,
    ) {
        if found.len() == index.len() {
            return;
        }
        match &tree.nodes[i].kind {
            Kind::Text(t) => {
                state.add_utf16(t);
                return;
            }
            Kind::Element { name, .. } => {
                if is_ruby_annotation(name) {
                    return;
                }
                let id = utf16(tree.id(i));
                if let Some(&w) = index.get(&id) {
                    if seen.insert(w) {
                        found.push((w, state.total()));
                    }
                }
            }
            _ => {}
        }
        for &c in &tree.nodes[i].children {
            visit(tree, c, index, seen, found, state);
        }
    }

    visit(tree, body, &index, &mut seen, &mut found, &mut state);
    found
}

// ---------------------------------------------------------------------------
// 插图扫描（原 _scanChapterImages / elementImageRefs / _sharesBlockWithText）
// ---------------------------------------------------------------------------

const IMAGE_BLOCK_TAGS: &[&str] = &[
    "address", "article", "aside", "blockquote", "body", "center", "dd", "div", "dl", "dt",
    "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "li", "main",
    "nav", "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul",
];

pub struct ImageHit {
    pub src: Vec<u16>,
    pub chars_before: u64,
    pub leading_anchor_ids: Vec<Vec<u16>>,
    pub shares_line_with_text: bool,
}

/// `EpubBook.svgImageHref`：属性名为 `href` / `xlink:href` / `*:href` 的第一个非空值。
fn svg_image_href(tree: &Tree, i: usize) -> Option<Vec<u16>> {
    if let Kind::Element { attrs, .. } = &tree.nodes[i].kind {
        for (name, _, value) in attrs {
            if name == "href" || name == "xlink:href" || name.ends_with(":href") {
                let v = utf16(value);
                let t = trim(&v);
                if !t.is_empty() {
                    return Some(t.to_vec());
                }
            }
        }
    }
    None
}

fn element_image_refs(tree: &Tree, i: usize, tag: &str) -> Vec<Vec<u16>> {
    let mut refs = Vec::new();
    if tag == "img" {
        let v = utf16(tree.attr(i, "src").unwrap_or(""));
        let t = trim(&v);
        if !t.is_empty() {
            refs.push(t.to_vec());
        }
    } else if tag == "image" {
        if let Some(href) = svg_image_href(tree, i) {
            refs.push(href);
        }
    }
    let style = tree.attr(i, "style").unwrap_or("");
    let su = utf16(style);
    if !trim(&su).is_empty() {
        let trimmed = String::from_utf16_lossy(trim(&su));
        push_background_urls(&trimmed, &mut refs);
    }
    refs
}

fn shares_block_with_text(tree: &Tree, element: usize) -> bool {
    let mut block = Some(element);
    while let Some(b) = block {
        let name = lower(tree.name(b).unwrap_or(""));
        if IMAGE_BLOCK_TAGS.contains(&name.as_str()) {
            break;
        }
        // `Element.parent`：父节点是元素时才有（Document 不算）。
        block = tree.nodes[b].parent.filter(|&p| tree.is_element(p));
    }
    let Some(block) = block else { return false };

    fn has_text(tree: &Tree, i: usize, block: usize) -> bool {
        match &tree.nodes[i].kind {
            Kind::Text(t) => return !trim(t).is_empty(),
            Kind::Element { name, .. } if i != block => {
                let tag = lower(name);
                if is_ruby_annotation(&tag) || IMAGE_BLOCK_TAGS.contains(&tag.as_str()) {
                    return false;
                }
            }
            _ => {}
        }
        tree.nodes[i].children.iter().any(|&c| has_text(tree, c, block))
    }

    has_text(tree, block, block)
}

pub struct ImageScan {
    pub hits: Vec<ImageHit>,
    pub total_chars: u64,
}

fn scan_images(tree: &Tree, body: Option<usize>) -> ImageScan {
    struct S {
        hits: Vec<ImageHit>,
        counter: StudyCharState,
        chars: u64,
        ids_at_count: Vec<Vec<u16>>,
    }
    fn visit(tree: &Tree, i: usize, s: &mut S) {
        match &tree.nodes[i].kind {
            Kind::Text(t) => {
                s.counter.add_utf16(t);
                if s.counter.total() > s.chars {
                    s.chars = s.counter.total();
                    s.ids_at_count = Vec::new();
                }
                return;
            }
            Kind::Element { name, .. } => {
                let tag = lower(name);
                if is_ruby_annotation(&tag) {
                    return;
                }
                let id = tree.id(i);
                if !id.is_empty() {
                    s.ids_at_count.push(utf16(id));
                }
                for src in element_image_refs(tree, i, &tag) {
                    s.hits.push(ImageHit {
                        src,
                        chars_before: s.chars,
                        leading_anchor_ids: s.ids_at_count.clone(),
                        shares_line_with_text: shares_block_with_text(tree, i),
                    });
                }
                for &c in &tree.nodes[i].children {
                    visit(tree, c, s);
                }
            }
            _ => {}
        }
    }
    let mut s = S {
        hits: Vec::new(),
        counter: StudyCharState::default(),
        chars: 0,
        ids_at_count: Vec::new(),
    };
    if let Some(b) = body {
        visit(tree, b, &mut s);
    }
    ImageScan {
        hits: s.hits,
        total_chars: s.chars,
    }
}

/// `EpubBook._chapterImageRefs`：整份文档（含 head）的 `<img src>`、SVG `<image>`、
/// 再是所有 `style=` 属性与 `<style>` 块拼成的 CSS 里的 background url。
fn chapter_image_refs(tree: &Tree) -> Vec<Vec<u16>> {
    let all = tree.descendants(0);
    let mut refs = Vec::new();
    for &i in &all {
        if tree.name(i) == Some("img") {
            let v = utf16(tree.attr(i, "src").unwrap_or(""));
            let t = trim(&v);
            if !t.is_empty() {
                refs.push(t.to_vec());
            }
        }
    }
    for &i in &all {
        if tree.name(i) == Some("image") {
            if let Some(href) = svg_image_href(tree, i) {
                refs.push(href);
            }
        }
    }
    let mut css = String::new();
    for &i in &all {
        if let Some(style) = tree.attr(i, "style") {
            css.push_str(style);
            css.push('\n');
        }
    }
    for &i in &all {
        if tree.name(i) == Some("style") {
            let mut buf = Vec::new();
            tree.text_of(i, &mut buf);
            css.push_str(&String::from_utf16_lossy(&buf));
            css.push('\n');
        }
    }
    push_background_urls(&css, &mut refs);
    refs
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// 请求位（可组合，一次解析算全部）。
pub mod flags {
    /// 纯文本 + 学习字数。
    pub const TEXT: u32 = 1;
    /// ruby 读音轨（含块尾 / 场景分隔；text 与 TEXT 的相同，不重复输出）。
    pub const RUBY: u32 = 2;
    /// 目录锚点偏移（需要 wanted ids）。
    pub const ANCHORS: u32 = 4;
    /// 插图扫描（body 内、带位置）。
    pub const IMAGES: u32 = 8;
    /// 整份文档的图片引用（纯图片章判定用）。
    pub const IMAGE_REFS: u32 = 16;
    /// 全书搜索用的原始文本：body 内文本节点按文档序直接拼接，只跳过 `rt` / `rp`
    /// 子树（`rtc` 本身的文字保留），不折叠空白——与 JS TreeWalker 同一坐标系。
    pub const SEARCH_TEXT: u32 = 32;
}

fn search_text(tree: &Tree, i: usize, out: &mut Vec<u16>) {
    match &tree.nodes[i].kind {
        Kind::Text(t) => out.extend_from_slice(t),
        Kind::Element { name, .. } => {
            if name == "rt" || name == "rp" {
                return;
            }
            for &c in &tree.nodes[i].children {
                search_text(tree, c, out);
            }
        }
        _ => {}
    }
}

struct Out(Vec<u16>);

impl Out {
    fn u32(&mut self, v: u64) {
        let v = v.min(u32::MAX as u64) as u32;
        self.0.push((v & 0xFFFF) as u16);
        self.0.push((v >> 16) as u16);
    }
    fn str(&mut self, s: &[u16]) {
        self.u32(s.len() as u64);
        self.0.extend_from_slice(s);
    }
}

/// 解析一章并按 [flags] 输出派生量。输出是一段 `u16` 流（小端 u32 拆成两个 u16，
/// 字符串 = u32 长度 + UTF-16 码元），各节按位序排列：
///
/// - TEXT：`study_chars:u32`、`text:str`
/// - RUBY：`n:u32` × (`start:u32 end:u32 reading:str`)、`n:u32` × `block_end:u32`、
///   `n:u32` × `scene_break:u32`（偏移相对 TEXT 的 text；要 RUBY 必须同时要 TEXT）
/// - ANCHORS：`n:u32` × (`wanted_index:u32 offset:u32`)
/// - IMAGES：`total_chars:u32`、`n:u32` × (`src:str chars_before:u32 shares_line:u32
///   n:u32 × id:str`)
/// - IMAGE_REFS：`n:u32` × `ref:str`
/// - SEARCH_TEXT：`text:str`
///
/// `wanted` 是 ANCHORS 的 id 列表，同样的 `str` 序列编码（`wanted_len` 为 u16 个数）。
/// 输出用 [ffc_parse_free_units] 释放。
///
/// # Safety
/// 指针按长度可读；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_epub_chapter(
    html: *const u8,
    html_len: usize,
    request: u32,
    wanted: *const u16,
    wanted_len: usize,
    out_ptr: *mut *mut u16,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null()
        || out_len.is_null()
        || (html_len > 0 && html.is_null())
        || (wanted_len > 0 && wanted.is_null())
    {
        return status::NULL_ARGUMENT;
    }
    if request & flags::RUBY != 0 && request & flags::TEXT == 0 {
        return status::INVALID_ARGUMENT;
    }
    guard(|| {
        let bytes: &[u8] = if html_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(html, html_len)
        };
        let Ok(source) = std::str::from_utf8(bytes) else {
            return status::BAD_INPUT;
        };
        let wanted_units: &[u16] = if wanted_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(wanted, wanted_len)
        };
        let Some(ids) = decode_strs(wanted_units) else {
            return status::INVALID_ARGUMENT;
        };
        let out = scan_chapter(source, request, &ids);
        let boxed = out.into_boxed_slice();
        *out_len = boxed.len();
        *out_ptr = Box::into_raw(boxed) as *mut u16;
        status::OK
    })
}

/// 释放 [ffc_parse_epub_chapter] 交出的 `u16` 缓冲区（长度为交出时的 u16 个数）。
#[no_mangle]
pub extern "C" fn ffc_parse_free_units(ptr: *mut u16, len: usize) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

fn decode_strs(units: &[u16]) -> Option<Vec<Vec<u16>>> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < units.len() {
        if i + 2 > units.len() {
            return None;
        }
        let n = units[i] as usize | ((units[i + 1] as usize) << 16);
        i += 2;
        if i + n > units.len() {
            return None;
        }
        out.push(units[i..i + n].to_vec());
        i += n;
    }
    Some(out)
}

/// 纯 Rust 入口（测试与 FFI 共用）。
pub fn scan_chapter(source: &str, request: u32, wanted: &[Vec<u16>]) -> Vec<u16> {
    let tree = Tree::parse(source);
    let body = tree.body();
    let mut out = Out(Vec::new());
    if request & flags::TEXT != 0 {
        let pt = plain_text(&tree, body);
        let mut st = StudyCharState::default();
        st.add_utf16(&pt.text);
        out.u32(st.total());
        out.str(&pt.text);
        if request & flags::RUBY != 0 {
            out.u32(pt.rubies.len() as u64);
            for r in &pt.rubies {
                out.u32(r.start as u64);
                out.u32(r.end as u64);
                out.str(&r.reading);
            }
            out.u32(pt.block_ends.len() as u64);
            for &e in &pt.block_ends {
                out.u32(e as u64);
            }
            out.u32(pt.scene_breaks.len() as u64);
            for &s in &pt.scene_breaks {
                out.u32(s as u64);
            }
        }
    }
    if request & flags::ANCHORS != 0 {
        let found = anchor_offsets(&tree, body, wanted);
        out.u32(found.len() as u64);
        for (w, o) in found {
            out.u32(w as u64);
            out.u32(o);
        }
    }
    if request & flags::IMAGES != 0 {
        let scan = scan_images(&tree, body);
        out.u32(scan.total_chars);
        out.u32(scan.hits.len() as u64);
        for h in &scan.hits {
            out.str(&h.src);
            out.u32(h.chars_before);
            out.u32(u64::from(h.shares_line_with_text));
            out.u32(h.leading_anchor_ids.len() as u64);
            for id in &h.leading_anchor_ids {
                out.str(id);
            }
        }
    }
    if request & flags::IMAGE_REFS != 0 {
        let refs = chapter_image_refs(&tree);
        out.u32(refs.len() as u64);
        for r in &refs {
            out.str(r);
        }
    }
    if request & flags::SEARCH_TEXT != 0 {
        let mut text = Vec::new();
        if let Some(b) = body {
            search_text(&tree, b, &mut text);
        }
        out.str(&text);
    }
    out.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(html: &str) -> String {
        let tree = Tree::parse(html);
        String::from_utf16(&plain_text(&tree, tree.body()).text).unwrap()
    }

    #[test]
    fn strips_ruby_and_collapses_whitespace() {
        assert_eq!(
            text("<body><p> 本文<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>  です。</p>\n<p>次</p></body>"),
            "本文漢字 です。 次"
        );
    }

    #[test]
    fn ruby_track() {
        let tree = Tree::parse("<body><p>a<ruby>漢<rp>(</rp><rt>か ん</rt><rp>)</rp></ruby></p></body>");
        let pt = plain_text(&tree, tree.body());
        assert_eq!(String::from_utf16(&pt.text).unwrap(), "a漢");
        assert_eq!(pt.rubies.len(), 1);
        assert_eq!((pt.rubies[0].start, pt.rubies[0].end), (1, 2));
        assert_eq!(String::from_utf16(&pt.rubies[0].reading).unwrap(), "かん");
        assert_eq!(pt.block_ends, vec![2]);
    }

    #[test]
    fn anchors_count_concatenated_prefix() {
        let tree = Tree::parse("<body><p>abc</p><p>def</p><h2 id=\"x\">見</h2><span id=\"\">y</span></body>");
        let found = anchor_offsets(&tree, tree.body(), &[utf16("x"), utf16(""), utf16("zz")]);
        assert_eq!(found, vec![(0, 1)]);
    }

    #[test]
    fn background_url_matches_like_dart() {
        let mut refs = Vec::new();
        push_background_urls("BACKGROUND:#fff URL( x.png ) ; background-image : url(\"a b.png\")", &mut refs);
        let got: Vec<String> = refs.iter().map(|r| String::from_utf16(r).unwrap()).collect();
        assert_eq!(got, vec!["x.png", "a b.png"]);
    }

    #[test]
    fn xlink_href_iterates_after_plain_attributes() {
        let tree = Tree::parse(
            "<body><svg xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image xlink:href=\"a.jpg\" href=\"b.jpg\"/></svg></body>",
        );
        let image = tree.descendants(0).into_iter().find(|&i| tree.name(i) == Some("image")).unwrap();
        assert_eq!(String::from_utf16(&svg_image_href(&tree, image).unwrap()).unwrap(), "b.jpg");
    }

    #[test]
    fn template_contents_are_children() {
        assert_eq!(text("<body><template><p>内</p></template><p>外</p></body>"), "内外");
    }
}

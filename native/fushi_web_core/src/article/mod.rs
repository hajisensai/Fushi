//! 网页小说正文提取 + 连载会话（[`session`]）。
//!
//! 一次调用交进整页 HTML 原始字节 + 页面 URL，出：章节标题、作品名 / 作者、清洗后的正文
//! XHTML 片段（保留段落、空行、ruby 注音、图片）、上一章 / 下一章 / 目录链接、语言提示。
//!
//! 取正文的顺序：
//! 1. **站点规则**（[`sites::SITE_RULES`]，数据表）命中主机且正文选择器有字 → 按规则取；
//! 2. **readability**（dom_smoothie，readability.js 的 Rust 移植）；
//! 3. **文本密度兜底**：直接文字（含 `<br>` 分隔文字）最多、链接最少的那个容器。
//!
//! 2 与 3 都跑、取字数多的那个：readability 对「整页只有一大段 `<br>` 文字」的中文站偶尔
//! 会只留半截。上下章链接：规则选择器 → 通用启发式（[`links`]）。

mod clean;
mod decode;
pub mod ffi;
mod links;
pub mod session;
mod sites;

#[cfg(test)]
mod tests;

use dom_query::{Document, Matcher, NodeRef};
use serde::Serialize;
use url::Url;

pub use clean::IMAGE_PLACEHOLDER_PREFIX;

/// 正文少于这么多字就当作没取到（导航页 / 验证页 / 目录页）。
pub const MIN_ARTICLE_CHARS: u32 = 20;

/// 一页的提取结果。`xhtml` 不进 JSON 头（大块数据单独走字节，见 [`encode_framed`]）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Article {
    /// 页面 URL（去掉片段；章节身份比较时再规范化，见 `session::canonical`）。
    pub url: String,
    pub title: String,
    pub work_title: Option<String>,
    pub author: Option<String>,
    /// BCP 47 主语言子标签（`ja` / `zh` / `ko` / `en`…）；判不出为 None。
    pub lang: Option<String>,
    pub site_rule: Option<String>,
    /// 作品身份：同一部作品的各章得出同一个键。
    pub work_key: String,
    pub next: Option<String>,
    pub prev: Option<String>,
    pub toc: Option<String>,
    /// 正文图片的绝对 URL；正文里第 i 张写作 `src="fushi-web-image:i"`。
    pub images: Vec<String>,
    pub excerpt: String,
    pub paragraphs: u32,
    pub chars: u32,
    /// `site` / `readability` / `density`。
    pub method: &'static str,
    /// 实际使用的字符集（`utf-8` / `gb18030` / `shift_jis`…）。
    pub charset: &'static str,
    /// 正文内容指纹（FNV-1a 64，十六进制）：URL 不同但正文相同的页去重用。
    pub content_hash: String,
    #[serde(skip)]
    pub xhtml: String,
}

impl Article {
    pub fn is_empty(&self) -> bool {
        self.chars < MIN_ARTICLE_CHARS
    }
}

/// 整页提取。`url` 不是 http(s) 绝对地址时报错。
pub fn extract(html: &[u8], url: &str) -> Result<Article, String> {
    let page = Url::parse(url).map_err(|e| format!("invalid page url: {e}"))?;
    if page.scheme() != "http" && page.scheme() != "https" {
        return Err(format!("unsupported url scheme: {}", page.scheme()));
    }
    let decoded = decode::decode_html(html);
    let doc = Document::from(decoded.text.as_str());
    let rule = page.host_str().and_then(sites::rule_for_host);

    let html_lang = doc
        .select_single("html")
        .attr("lang")
        .map(|l| l.trim().to_owned())
        .filter(|l| !l.is_empty());
    let page_title = doc.select_single("title").text().trim().to_owned();

    // ── 正文 ──
    let mut chosen: Option<(clean::Cleaned, &'static str)> = None;
    if let Some(rule) = rule {
        let remove = (!rule.remove.is_empty())
            .then(|| Matcher::new(rule.remove).ok())
            .flatten();
        if let Some(selection) = doc.try_select(rule.body) {
            let roots = top_level(selection.nodes());
            if !roots.is_empty() {
                let mut cleaner = clean::Cleaner::new(Some(&page), remove.as_ref(), false);
                for root in &roots {
                    cleaner.feed(root);
                }
                let cleaned = cleaner.finish();
                if cleaned.chars >= MIN_ARTICLE_CHARS {
                    chosen = Some((cleaned, "site"));
                }
            }
        }
    }

    // 通用：先在原文档上取链接 / 标题素材（readability 会改写文档），再交给它。
    let rule_links = rule.map(|r| links::NavLinks {
        next: links::link_by_selector(&doc, r.next, &page),
        prev: links::link_by_selector(&doc, r.prev, &page),
        toc: links::link_by_selector(&doc, r.toc, &page),
    });
    let generic_links = links::find_nav_links(&doc, &page);
    let headings: Vec<String> = doc
        .select("h1, h2, h3")
        .nodes()
        .iter()
        .map(|n| collapse_ws(&n.text()))
        .filter(|t| !t.is_empty() && t.chars().count() <= 80)
        .collect();
    let rule_title = rule.and_then(|r| first_text(&doc, r.title));
    let rule_work_title = rule.and_then(|r| first_text(&doc, r.work_title));
    let rule_author = rule.and_then(|r| first_text(&doc, r.author));
    let meta_author = doc
        .select_single("meta[name='author']")
        .attr("content")
        .map(|a| collapse_ws(&a))
        .filter(|a| !a.is_empty());

    if chosen.is_none() {
        let density = density_fallback(&doc, &page);
        let readable = readability_content(doc, &page);
        chosen = match (readable, density) {
            (Some(r), Some(d)) => {
                // readability 只留了半截（< 60%）时用密度结果。
                if (r.chars as f64) < d.chars as f64 * 0.6 {
                    Some((d, "density"))
                } else {
                    Some((r, "readability"))
                }
            }
            (Some(r), None) => Some((r, "readability")),
            (None, Some(d)) => Some((d, "density")),
            (None, None) => None,
        };
    }
    let (cleaned, method) = chosen.unwrap_or_else(|| {
        (
            clean::Cleaner::new(Some(&page), None, false).finish(),
            "none",
        )
    });

    // ── 链接 ──
    let mut nav = generic_links;
    if let Some(rl) = rule_links {
        if rl.next.is_some() {
            nav.next = rl.next;
        }
        if rl.prev.is_some() {
            nav.prev = rl.prev;
        }
        if rl.toc.is_some() {
            nav.toc = rl.toc;
        }
    }
    if let (Some(n), Some(t)) = (&nav.next, &nav.toc) {
        if links::same_page(n, t) {
            nav.next = None;
        }
    }

    // ── 标题 ──
    let title = rule_title
        .clone()
        .or_else(|| chapter_like_heading(&headings))
        .or_else(|| title_segment(&page_title, rule_work_title.as_deref()))
        .unwrap_or_else(|| page_title.clone());
    let work_title = rule_work_title
        .or_else(|| work_title_guess(&page_title, &headings, &title))
        .map(|t| strip_brackets(&t))
        .filter(|t| !t.is_empty() && *t != title);

    let lang = detect_script_lang(&cleaned.text)
        .map(str::to_owned)
        .or_else(|| html_lang.as_deref().map(primary_subtag))
        .or_else(|| rule.and_then(|r| r.lang).map(str::to_owned));

    let mut page_url = page.clone();
    page_url.set_fragment(None);
    Ok(Article {
        url: page_url.to_string(),
        title,
        work_title,
        author: rule_author.or(meta_author),
        lang,
        site_rule: rule.map(|r| r.id.to_owned()),
        work_key: work_key_for(&page, nav.toc.as_ref()),
        next: nav.next.map(|u| u.to_string()),
        prev: nav.prev.map(|u| u.to_string()),
        toc: nav.toc.map(|u| u.to_string()),
        images: cleaned.images,
        excerpt: cleaned.excerpt,
        paragraphs: cleaned.paragraphs,
        chars: cleaned.chars,
        method,
        charset: decoded.charset,
        content_hash: format!("{:016x}", fnv1a(cleaned.text.as_bytes())),
        xhtml: cleaned.xhtml,
    })
}

/// 只从 URL 推作品身份（Dart 在提取前用它找书架上已有的同一部作品）。
pub fn work_key_for_url(url: &str) -> Option<String> {
    let page = Url::parse(url).ok()?;
    if page.scheme() != "http" && page.scheme() != "https" {
        return None;
    }
    Some(work_key_for(&page, None))
}

fn work_key_for(page: &Url, _toc: Option<&Url>) -> String {
    let host = page
        .host_str()
        .map(sites::normalized_host)
        .unwrap_or_default();
    let segments: Vec<&str> = page
        .path_segments()
        .map(|s| s.filter(|seg| !seg.is_empty()).collect())
        .unwrap_or_default();
    match page
        .host_str()
        .and_then(sites::rule_for_host)
        .map(|r| r.work_key)
    {
        Some(sites::WorkKeyRule::PathSegments(n)) => {
            let take = n.min(segments.len());
            format!("{host}/{}", segments[..take].join("/"))
        }
        Some(sites::WorkKeyRule::QueryParam(name)) => {
            let value = page
                .query_pairs()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.into_owned())
                .unwrap_or_default();
            format!("{host}?{name}={value}")
        }
        // 通用：章节页所在目录（`/book/123/456.html` → `/book/123`）。
        // 查询串里不像「章 / 页序号」的参数也算作品身份（`read.php?book=7&chapter=3`）。
        None => {
            let take = segments.len().saturating_sub(1);
            let mut key = format!("{host}/{}", segments[..take].join("/"));
            let mut params: Vec<(String, String)> = page
                .query_pairs()
                .filter(|(k, _)| {
                    let k = k.to_ascii_lowercase();
                    !["chapter", "cid", "page", "ep", "part"]
                        .iter()
                        .any(|w| k.contains(w))
                        && k != "p"
                        && k != "no"
                })
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect();
            params.sort();
            if !params.is_empty() {
                let query: Vec<String> = params.iter().map(|(k, v)| format!("{k}={v}")).collect();
                key.push('?');
                key.push_str(&query.join("&"));
            }
            key
        }
    }
}

/// 选择器结果里去掉「祖先也在结果里」的节点（避免同一段文字进两次）。
fn top_level<'a>(nodes: &[NodeRef<'a>]) -> Vec<NodeRef<'a>> {
    let ids: Vec<_> = nodes.iter().map(|n| n.id).collect();
    nodes
        .iter()
        .filter(|n| !n.ancestors_it(None).any(|a| ids.contains(&a.id)))
        .cloned()
        .collect()
}

fn first_text(doc: &Document, selector: &str) -> Option<String> {
    if selector.is_empty() {
        return None;
    }
    let selection = doc.try_select(selector)?;
    selection.nodes().iter().find_map(|n| {
        let text = collapse_ws(&n.text());
        let text = if text.is_empty() {
            n.attr("title").map(|t| collapse_ws(&t)).unwrap_or_default()
        } else {
            text
        };
        (!text.is_empty()).then_some(text)
    })
}

fn readability_content(doc: Document, page: &Url) -> Option<clean::Cleaned> {
    let cfg = dom_smoothie::Config {
        max_elements_to_parse: 0,
        char_threshold: 200,
        // 留 class / id：清洗阶段按它们剔广告位与站内提示。
        keep_classes: true,
        ..Default::default()
    };
    let mut readability =
        dom_smoothie::Readability::with_document(doc, Some(page.as_str()), Some(cfg)).ok()?;
    let article = readability.parse().ok()?;
    let fragment = Document::fragment(article.content.to_string());
    let mut cleaner = clean::Cleaner::new(Some(page), None, true);
    cleaner.feed(&fragment.root());
    let cleaned = cleaner.finish();
    (cleaned.chars >= MIN_ARTICLE_CHARS).then_some(cleaned)
}

/// 文本密度兜底：每个块容器的「直接文字」（自身文本节点 + `<p>` / `<br>` 子级里的文字）
/// 减去链接文字，取最大的那个。
fn density_fallback(doc: &Document, page: &Url) -> Option<clean::Cleaned> {
    let mut best: Option<(i64, NodeRef)> = None;
    for node in doc
        .select("body div, body article, body section, body main, body td")
        .nodes()
    {
        let mut direct = 0i64;
        for child in node.children_it(false) {
            if child.is_text() {
                direct += visible_len(&child.text()) as i64;
            } else if child.is_element() {
                let name = child
                    .node_name()
                    .map(|n| n.to_ascii_lowercase())
                    .unwrap_or_default();
                if name == "p" || name == "span" || name == "font" {
                    direct += visible_len(&child.text()) as i64;
                }
            }
        }
        if direct == 0 {
            continue;
        }
        let link_text: i64 = node
            .descendants_it()
            .filter(|d| d.node_name().is_some_and(|n| n.eq_ignore_ascii_case("a")))
            .map(|a| visible_len(&a.text()) as i64)
            .sum();
        let score = direct - link_text * 2;
        if best.as_ref().is_none_or(|(s, _)| score > *s) {
            best = Some((score, *node));
        }
    }
    let (_, root) = best?;
    let mut cleaner = clean::Cleaner::new(Some(page), None, true);
    cleaner.feed(&root);
    let cleaned = cleaner.finish();
    (cleaned.chars >= MIN_ARTICLE_CHARS).then_some(cleaned)
}

fn visible_len(s: &str) -> usize {
    s.chars().filter(|c| !c.is_whitespace()).count()
}

/// 折叠 ASCII 空白（全角空格是标题 / 作品名的一部分，原样保留）。
fn collapse_ws(s: &str) -> String {
    s.split(|c: char| c.is_ascii_whitespace())
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches('\u{3000}')
        .to_owned()
}

/// 像章节标题的标题（「第十二章 …」「第3話」「Chapter 4」「プロローグ」…）。
fn chapter_like_heading(headings: &[String]) -> Option<String> {
    headings.iter().find(|h| is_chapter_like(h)).cloned()
}

fn is_chapter_like(s: &str) -> bool {
    let t = s.trim();
    let lower = t.to_lowercase();
    if lower.starts_with("chapter") || lower.starts_with("episode") || lower.starts_with("ch.") {
        return true;
    }
    for word in [
        "プロローグ",
        "エピローグ",
        "序章",
        "终章",
        "終章",
        "楔子",
        "番外",
        "后记",
        "後書き",
    ] {
        if t.starts_with(word) {
            return true;
        }
    }
    let mut chars = t.chars();
    if chars.next() == Some('第') {
        let numeral = |c: char| {
            c.is_ascii_digit()
                || ('０'..='９').contains(&c)
                || "一二三四五六七八九十百千万零〇两壹贰叁肆伍陆柒捌玖拾佰仟".contains(c)
        };
        let mut seen = false;
        for c in chars.by_ref() {
            if numeral(c) || c.is_whitespace() {
                seen |= numeral(c);
                continue;
            }
            return seen && "章話话回节節卷部篇幕".contains(c);
        }
    }
    false
}

/// `<title>` 按分隔符切段后，挑不是作品名、不是站名的那段当章节标题。
fn title_segment(page_title: &str, work_title: Option<&str>) -> Option<String> {
    let parts = split_title(page_title);
    if parts.len() < 2 {
        return None;
    }
    if let Some(found) = parts.iter().find(|p| is_chapter_like(p)) {
        return Some(found.clone());
    }
    let work = work_title.map(strip_brackets);
    parts
        .into_iter()
        .find(|p| work.as_deref().is_none_or(|w| strip_brackets(p) != w))
}

fn split_title(page_title: &str) -> Vec<String> {
    let mut parts = vec![page_title.to_owned()];
    for sep in [" - ", " | ", "｜", " – ", " — ", "_", "：", " / ", "^"] {
        parts = parts
            .into_iter()
            .flat_map(|p| p.split(sep).map(str::to_owned).collect::<Vec<_>>())
            .collect();
    }
    parts
        .into_iter()
        .map(|p| p.trim().trim_matches('　').to_owned())
        .filter(|p| !p.is_empty())
        .collect()
}

fn work_title_guess(page_title: &str, headings: &[String], title: &str) -> Option<String> {
    // 不像章节标题、且在 <title> 里出现过的 h1。
    if let Some(h) = headings
        .iter()
        .find(|h| !is_chapter_like(h) && *h != title && page_title.contains(h.as_str()))
    {
        return Some(h.clone());
    }
    let parts = split_title(page_title);
    if parts.len() >= 2 {
        return parts
            .into_iter()
            .find(|p| p != title && !is_chapter_like(p));
    }
    None
}

fn strip_brackets(s: &str) -> String {
    s.trim()
        .trim_start_matches(['《', '「', '『', '【'])
        .trim_end_matches(['》', '」', '』', '】'])
        .trim()
        .to_owned()
}

fn primary_subtag(tag: &str) -> String {
    tag.split(['-', '_'])
        .next()
        .unwrap_or(tag)
        .to_ascii_lowercase()
}

/// 按正文用字判 CJK 语言（比 `<html lang>` 可靠：不少站整站写死 `lang="en"`）。
fn detect_script_lang(text: &str) -> Option<&'static str> {
    let (mut kana, mut han, mut hangul, mut sample) = (0usize, 0usize, 0usize, 0usize);
    for c in text.chars().filter(|c| !c.is_whitespace()).take(4000) {
        sample += 1;
        match c {
            '\u{3040}'..='\u{30FF}' | '\u{31F0}'..='\u{31FF}' | '\u{FF66}'..='\u{FF9F}' => {
                kana += 1
            }
            '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}' => han += 1,
            '\u{AC00}'..='\u{D7AF}' | '\u{1100}'..='\u{11FF}' => hangul += 1,
            _ => {}
        }
    }
    if sample == 0 {
        return None;
    }
    let cjk = kana + han + hangul;
    if cjk * 5 < sample {
        return None;
    }
    if kana * 50 >= kana + han && kana > 0 {
        Some("ja")
    } else if hangul > han {
        Some("ko")
    } else if han > 0 {
        Some("zh")
    } else {
        None
    }
}

pub(crate) fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// 帧格式：`[u32 LE 头长度][JSON 头][正文 XHTML 的 UTF-8 字节]`。正文不进 JSON（不转义、
/// 不来回编码），Dart 侧按长度切出来直接解码。
pub(crate) fn encode_framed<T: Serialize>(header: &T, body: &str) -> Result<Vec<u8>, String> {
    let json = serde_json::to_vec(header).map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(4 + json.len() + body.len());
    out.extend_from_slice(&(json.len() as u32).to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(body.as_bytes());
    Ok(out)
}

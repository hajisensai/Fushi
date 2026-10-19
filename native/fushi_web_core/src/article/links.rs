//! 上一章 / 下一章 / 目录链接的通用启发式（站点规则没给或没命中时用）。
//!
//! 打分从强到弱：`rel=next/prev`（`<link>` 与 `<a>`）> id / class 里的 next / prev 字样 >
//! 锚文字恰好是「下一章 / 次へ / 次の話 / Next…」> 锚文字包含这些词 > URL 递增模式（页面里
//! 确实有一个链接与当前 URL 只差末尾数字 ±1）。只认页面里**真实存在**的链接，不凭空构造 URL。

use dom_query::{Document, NodeRef};
use url::Url;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum LinkKind {
    Next,
    Prev,
    Toc,
}

const NEXT_WORDS: &[&str] = &[
    "下一章",
    "下一章节",
    "下章",
    "后一章",
    "下一节",
    "下一話",
    "下一话",
    "次へ",
    "次の話",
    "次話",
    "次のエピソード",
    "次のページ",
    "次",
    "next",
    "nextchapter",
    "nextepisode",
    "nextpage",
    "下一页",
];
const PREV_WORDS: &[&str] = &[
    "上一章",
    "上一章节",
    "上章",
    "前一章",
    "上一节",
    "上一話",
    "上一话",
    "前へ",
    "前の話",
    "前話",
    "前のエピソード",
    "前のページ",
    "前",
    "prev",
    "previous",
    "previouschapter",
    "prevchapter",
    "previousepisode",
    "上一页",
];
const TOC_WORDS: &[&str] = &[
    "目录",
    "目錄",
    "章节目录",
    "章節目錄",
    "返回目录",
    "回目录",
    "目次",
    "目　次",
    "もくじ",
    "index",
    "contents",
    "tableofcontents",
    "toc",
    "chapterlist",
    "返回书页",
    "书页",
];

/// 选出来的三个链接（绝对 URL）。
#[derive(Default, Debug, Clone)]
pub(crate) struct NavLinks {
    pub next: Option<Url>,
    pub prev: Option<Url>,
    pub toc: Option<Url>,
}

/// 锚文字归一化：去空白、箭头、括号与常见装饰符，ASCII 转小写。
pub(crate) fn normalize_label(label: &str) -> String {
    label
        .chars()
        .filter(|c| {
            !c.is_whitespace()
                && !matches!(
                    c,
                    '<' | '>'
                        | '«'
                        | '»'
                        | '‹'
                        | '›'
                        | '←'
                        | '→'
                        | '〈'
                        | '〉'
                        | '《'
                        | '》'
                        | '【'
                        | '】'
                        | '['
                        | ']'
                        | '('
                        | ')'
                        | '（'
                        | '）'
                        | '「'
                        | '」'
                        | '・'
                        | '·'
                        | '|'
                        | '｜'
                        | ':'
                        | '：'
                        | '-'
                        | '－'
                        | '_'
                        | '＞'
                        | '＜'
                        | '▶'
                        | '◀'
                        | '►'
                        | '◄'
                        | '.'
                        | '…'
                        | '\u{3000}'
                )
        })
        .collect::<String>()
        .to_lowercase()
}

/// 把 href 解析成可导航的绝对 http(s) URL（去掉片段）。
pub(crate) fn resolve_href(base: &Url, href: &str) -> Option<Url> {
    let href = href.trim();
    if href.is_empty()
        || href.starts_with('#')
        || href.to_ascii_lowercase().starts_with("javascript:")
    {
        return None;
    }
    let mut url = base.join(href).ok()?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return None;
    }
    url.set_fragment(None);
    Some(url)
}

/// 两个 URL 指同一页（忽略片段、末尾斜杠、主机大小写与 www.）。
pub(crate) fn same_page(a: &Url, b: &Url) -> bool {
    canonical_url(a) == canonical_url(b)
}

/// 章节身份用的规范 URL 串：scheme 统一 https、小写主机去 `www.`、去片段、去末尾斜杠。
pub(crate) fn canonical_url(url: &Url) -> String {
    let host = url
        .host_str()
        .map(super::sites::normalized_host)
        .unwrap_or_default();
    let path = url.path().trim_end_matches('/');
    match url.query() {
        Some(q) if !q.is_empty() => format!("https://{host}{path}?{q}"),
        _ => format!("https://{host}{path}"),
    }
}

struct Candidate {
    url: Url,
    score: u32,
    order: usize,
}

fn classify(label: &str, words: &[&str]) -> u32 {
    if label.is_empty() {
        return 0;
    }
    if words.contains(&label) {
        return 60;
    }
    // 「次の話へ」「下一章→」「Next Chapter 12」这类：包含即可，但单字词（次 / 前）只认整串。
    if words
        .iter()
        .filter(|w| w.chars().count() >= 2)
        .any(|w| label.contains(w))
        && label.chars().count() <= 16
    {
        return 40;
    }
    0
}

fn attr_hint(node: &NodeRef, kind: LinkKind) -> u32 {
    let class = node
        .attr("class")
        .map(|c| c.to_ascii_lowercase())
        .unwrap_or_default();
    let id = node
        .attr("id")
        .map(|c| c.to_ascii_lowercase())
        .unwrap_or_default();
    let hay = format!("{class} {id}");
    let hit = match kind {
        LinkKind::Next => hay.contains("next"),
        LinkKind::Prev => {
            hay.contains("prev") || hay.contains("before") || hay.contains("previous")
        }
        LinkKind::Toc => hay.contains("toc") || hay.contains("catalog") || hay.contains("index"),
    };
    if hit {
        50
    } else {
        0
    }
}

/// 末尾那段数字（路径或查询里最后出现的整数）及其位置。
fn last_number(s: &str) -> Option<(usize, usize, u64)> {
    let bytes = s.as_bytes();
    let mut end = bytes.len();
    while end > 0 && !bytes[end - 1].is_ascii_digit() {
        end -= 1;
    }
    if end == 0 {
        return None;
    }
    let mut start = end;
    while start > 0 && bytes[start - 1].is_ascii_digit() {
        start -= 1;
    }
    let n = s[start..end].parse::<u64>().ok()?;
    Some((start, end, n))
}

/// `b` 是否是 `a` 末尾数字 +delta（其余部分完全相同）。
fn is_increment(a: &str, b: &str, delta: i64) -> bool {
    let (Some((sa, ea, na)), Some((sb, eb, nb))) = (last_number(a), last_number(b)) else {
        return false;
    };
    a[..sa] == b[..sb] && a[ea..] == b[eb..] && (nb as i64 - na as i64) == delta
}

/// 在整页里找上一章 / 下一章 / 目录。
pub(crate) fn find_nav_links(doc: &Document, page: &Url) -> NavLinks {
    let mut next: Vec<Candidate> = Vec::new();
    let mut prev: Vec<Candidate> = Vec::new();
    let mut toc: Vec<Candidate> = Vec::new();
    let page_key = canonical_url(page);

    for (order, node) in doc
        .select("link[rel][href], a[href]")
        .nodes()
        .iter()
        .enumerate()
    {
        let Some(href) = node.attr("href") else {
            continue;
        };
        let Some(url) = resolve_href(page, &href) else {
            continue;
        };
        let key = canonical_url(&url);
        if key == page_key {
            continue;
        }
        let rel = node
            .attr("rel")
            .map(|r| r.to_ascii_lowercase())
            .unwrap_or_default();
        let rels: Vec<&str> = rel.split_whitespace().collect();
        let is_link_tag = node
            .node_name()
            .is_some_and(|n| n.eq_ignore_ascii_case("link"));
        let text = if is_link_tag {
            String::new()
        } else {
            node.text().to_string()
        };
        let mut label = normalize_label(&text);
        if label.is_empty() {
            label = normalize_label(
                &node
                    .attr("title")
                    .or_else(|| node.attr("aria-label"))
                    .unwrap_or_default(),
            );
        }
        let push = |list: &mut Vec<Candidate>, score: u32| {
            if score > 0 {
                list.push(Candidate {
                    url: url.clone(),
                    score,
                    order,
                });
            }
        };
        if rels.contains(&"next") {
            push(&mut next, 100);
        }
        if rels.contains(&"prev") || rels.contains(&"previous") {
            push(&mut prev, 100);
        }
        if is_link_tag {
            continue;
        }
        let next_text = classify(&label, NEXT_WORDS);
        let prev_text = classify(&label, PREV_WORDS);
        let toc_text = classify(&label, TOC_WORDS);
        let hinted = |text: u32, kind: LinkKind| {
            if text > 0 {
                text + attr_hint(node, kind) / 5
            } else {
                attr_hint(node, kind) / 2
            }
        };
        push(&mut next, hinted(next_text, LinkKind::Next));
        push(&mut prev, hinted(prev_text, LinkKind::Prev));
        push(
            &mut toc,
            if toc_text > 0 {
                toc_text + attr_hint(node, LinkKind::Toc) / 5
            } else {
                0
            },
        );
        if next_text == 0 && prev_text == 0 {
            if is_increment(&page_key, &key, 1) {
                push(&mut next, 10);
            } else if is_increment(&page_key, &key, -1) {
                push(&mut prev, 10);
            }
        }
    }

    let pick = |list: Vec<Candidate>| -> Option<Url> {
        list.into_iter()
            .max_by(|a, b| a.score.cmp(&b.score).then(b.order.cmp(&a.order)))
            .map(|c| c.url)
    };
    let mut links = NavLinks {
        next: pick(next),
        prev: pick(prev),
        toc: pick(toc),
    };
    // 末章的「下一章」常常指回目录：那不是下一章。
    if let (Some(n), Some(t)) = (&links.next, &links.toc) {
        if same_page(n, t) {
            links.next = None;
        }
    }
    links
}

/// 站点规则的选择器取链接（第一个能解析的）。
pub(crate) fn link_by_selector(doc: &Document, selector: &str, page: &Url) -> Option<Url> {
    if selector.is_empty() {
        return None;
    }
    let selection = doc.try_select(selector)?;
    selection
        .nodes()
        .iter()
        .filter_map(|n| n.attr("href").and_then(|h| resolve_href(page, &h)))
        .find(|u| !same_page(u, page))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn links(html: &str, page: &str) -> NavLinks {
        find_nav_links(&Document::from(html), &Url::parse(page).unwrap())
    }

    #[test]
    fn rel_beats_text() {
        let l = links(
            "<link rel='next' href='/w/3'><a href='/w/9'>下一章</a><a href='/w/1'>上一章</a><a href='/w/'>目录</a>",
            "https://a.example/w/2",
        );
        assert_eq!(l.next.unwrap().as_str(), "https://a.example/w/3");
        assert_eq!(l.prev.unwrap().as_str(), "https://a.example/w/1");
        assert_eq!(l.toc.unwrap().as_str(), "https://a.example/w/");
    }

    #[test]
    fn japanese_arrows_and_words() {
        let l = links(
            "<a href='./1.html'>&lt;&lt; 前の話</a><a href='./'>目 次</a><a href='./3.html'>次の話 &gt;&gt;</a>",
            "https://syosetu.org/novel/5/2.html",
        );
        assert_eq!(
            l.next.unwrap().as_str(),
            "https://syosetu.org/novel/5/3.html"
        );
        assert_eq!(
            l.prev.unwrap().as_str(),
            "https://syosetu.org/novel/5/1.html"
        );
        assert_eq!(l.toc.unwrap().as_str(), "https://syosetu.org/novel/5/");
    }

    #[test]
    fn url_increment_when_no_words() {
        let l = links(
            "<a href='onebook.php?novelid=7&chapterid=3'>→</a><a href='onebook.php?novelid=7&chapterid=1'>←</a>",
            "https://www.jjwxc.net/onebook.php?novelid=7&chapterid=2",
        );
        assert!(l.next.unwrap().as_str().ends_with("chapterid=3"));
        assert!(l.prev.unwrap().as_str().ends_with("chapterid=1"));
    }

    #[test]
    fn next_pointing_at_toc_is_dropped() {
        let l = links(
            "<a href='/book/1/'>下一章</a><a href='/book/1/'>返回目录</a>",
            "https://b.example/book/1/99.html",
        );
        assert!(l.next.is_none());
        assert!(l.toc.is_some());
    }

    #[test]
    fn javascript_and_fragment_links_ignored() {
        let l = links(
            "<a href='javascript:void(0)'>下一章</a><a href='#top'>Next</a>",
            "https://c.example/x/1",
        );
        assert!(l.next.is_none());
    }
}

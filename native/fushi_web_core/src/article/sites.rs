//! 站点特化规则（数据表）。命中规则时正文 / 标题 / 上下章全按选择器取，不跑通用算法；
//! 规则里留空的项退回通用启发式（[`super::links`] / 标题推断）。
//!
//! 选择器是 CSS（dom_query / selectors 语法）。新增站点只加一行表项；`tests.rs` 会逐条编译
//! 全部选择器，写错了 `cargo test` 就红。
//!
//! 核实状态（真实页面快照在 `tests/vectors/article/inputs/`）：
//! - `syosetu`（小説家になろう）、`kakuyomu`（カクヨム）、`jjwxc`（晋江文学城）：有真实页面快照；
//! - `hameln`（ハーメルン）：站点对非浏览器请求一律给 Cloudflare 质询页，本机抓不到真实页面，
//!   规则按站点已知结构写、只有合成快照覆盖——**未经真实页面验证**，选择器不中时通用算法兜底。

/// 作品身份（同一部作品的不同章节得出同一个键）怎么从章节 URL 推。
#[derive(Clone, Copy, Debug)]
pub(crate) enum WorkKeyRule {
    /// 路径前 N 段（`/n9669bk/1/` 取 1 段 → `/n9669bk`）。
    PathSegments(usize),
    /// 查询参数（晋江 `onebook.php?novelid=…&chapterid=…` 取 `novelid`）。
    QueryParam(&'static str),
}

#[derive(Debug)]
pub(crate) struct SiteRule {
    pub id: &'static str,
    /// 精确主机名（比较前去掉 `www.`）。
    pub hosts: &'static [&'static str],
    pub lang: Option<&'static str>,
    pub work_key: WorkKeyRule,
    /// 章节标题。
    pub title: &'static str,
    /// 作品名。
    pub work_title: &'static str,
    pub author: &'static str,
    /// 正文容器（多个匹配按文档顺序拼接：前言 / 正文 / 后记）。
    pub body: &'static str,
    /// 正文容器里要剔除的子树（按钮、站内提示、书签控件）。
    pub remove: &'static str,
    pub next: &'static str,
    pub prev: &'static str,
    pub toc: &'static str,
}

pub(crate) static SITE_RULES: &[SiteRule] = &[
    SiteRule {
        id: "syosetu",
        hosts: &["ncode.syosetu.com", "novel18.syosetu.com"],
        lang: Some("ja"),
        work_key: WorkKeyRule::PathSegments(1),
        title: ".p-novel__title, .novel_subtitle",
        work_title: ".c-announce a[href^='/'], .contents1 > a",
        author: ".c-announce a[href*='mypage.syosetu.com']",
        body: ".p-novel__body .js-novel-text, #novel_p, #novel_honbun, #novel_a",
        remove: "",
        next: "a.c-pager__item--next, .novel_bn a.novelview_pager-next",
        prev: "a.c-pager__item--before, .novel_bn a.novelview_pager-before",
        toc: ".c-pager a.c-pager__item:not(.c-pager__item--next):not(.c-pager__item--before)",
    },
    SiteRule {
        id: "kakuyomu",
        hosts: &["kakuyomu.jp"],
        lang: Some("ja"),
        work_key: WorkKeyRule::PathSegments(2),
        title: ".widget-episodeTitle",
        work_title: "#worksEpisodesEpisodeHeader-breadcrumbs h1 a",
        // 章节页只有账号 id（dataLayer 的 workAuthorName），没有笔名：不取。
        author: "",
        body: ".widget-episodeBody",
        remove: "",
        next: "link[rel='next'], #contentMain-readNextEpisode",
        prev: "link[rel='prev'], #contentMain-readPreviousEpisode",
        toc: "#worksEpisodesEpisodeHeader-breadcrumbs h1 a",
    },
    SiteRule {
        id: "hameln",
        hosts: &["syosetu.org"],
        lang: Some("ja"),
        work_key: WorkKeyRule::PathSegments(2),
        title: "#maind .ss > span[style*='120%']",
        work_title: "#maind .ss p span[style*='120%'] a",
        author: "#maind .ss p a[href*='/user/']",
        body: "#honbun",
        remove: "",
        next: "a.next_page_link",
        prev: "a.prev_page_link",
        toc: "",
    },
    SiteRule {
        id: "jjwxc",
        hosts: &["jjwxc.net", "my.jjwxc.net"],
        lang: Some("zh"),
        work_key: WorkKeyRule::QueryParam("novelid"),
        title: ".noveltext h2",
        work_title: ".noveltitle h1 .bigtext, .noveltitle h1",
        author: ".noveltitle a[href*='oneauthor.php']",
        body: "#paragraph_comment_content",
        // 正文容器里混着「插入书签」控件（`div[align=right]` 里的 `.favorite_novel`）。
        remove: ".readsmall, #note_danmu_wrapper, .favorite_novel, div[align='right'], [id^='favoriteshow']",
        next: "#chapter_next_link",
        prev: "#chapter_prev_link",
        toc: "",
    },
];

/// 规则表里比较用的主机名：小写、去掉 `www.`。
pub(crate) fn normalized_host(host: &str) -> String {
    let lower = host.to_ascii_lowercase();
    lower
        .strip_prefix("www.")
        .map(str::to_owned)
        .unwrap_or(lower)
}

pub(crate) fn rule_for_host(host: &str) -> Option<&'static SiteRule> {
    let host = normalized_host(host);
    SITE_RULES.iter().find(|r| r.hosts.contains(&host.as_str()))
}

//! 连载会话：一部网页小说「已提取了哪些章、按什么顺序、下一章去哪取」的状态。
//!
//! 状态全在这里，Dart 只发三种命令（开会话 / 喂一页 HTML / 取快照），并把快照 JSON 原样存进
//! 书行（`EpubBooks.sourceMetadata`）；下次开会话时把它交回来恢复。快照里**没有**正文（正文
//! 在书的解压树里，那是 EPUB 的事），只有章节元数据，几 KB 量级。
//!
//! 规则：
//! - 作品身份 `workKey` 由第一章定下，之后喂进来的别的作品的页一律拒收（`otherWork`）；
//! - 去重：规范 URL 相同，或正文指纹相同（同一章换了 URL 形式）→ 原地更新元数据（`updated`），
//!   典型情形是「上次的末章当时还没有下一章，现在有了」；
//! - 排序：新章按章节之间互相声明的 next / prev 链接插到对的位置，链不上就追加到末尾；
//! - 下一章队列：每章声明的 next 里还没取过的（去掉指回目录的），按章序。`tailNext` 是末章的
//!   下一章——追更就取它。

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use super::Article;

/// 快照里的类型标记（Dart 侧按它在书行里认出网页小说书）。
pub const SNAPSHOT_TYPE: &str = "fushi_web_novel";
pub const SNAPSHOT_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChapterMeta {
    pub url: String,
    pub title: String,
    #[serde(default)]
    pub next: Option<String>,
    #[serde(default)]
    pub prev: Option<String>,
    #[serde(default)]
    pub chars: u32,
    #[serde(default)]
    pub hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    #[serde(rename = "type")]
    pub kind: String,
    pub version: u32,
    #[serde(default)]
    pub work_key: Option<String>,
    #[serde(default)]
    pub site_rule: Option<String>,
    #[serde(default)]
    pub work_title: Option<String>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub lang: Option<String>,
    #[serde(default)]
    pub toc: Option<String>,
    #[serde(default)]
    pub chapters: Vec<ChapterMeta>,
    /// 派生字段（每次改动后重算；恢复时忽略存档里的值）。
    #[serde(default)]
    pub queue: Vec<String>,
    #[serde(default)]
    pub tail_next: Option<String>,
}

/// 一次喂页的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum IngestStatus {
    /// 新章，已插入。
    Added,
    /// 已有的章（URL 或正文相同）：元数据已更新。
    Updated,
    /// 正文没取到（导航页 / 验证页 / 目录页）：没有进会话。
    Empty,
    /// 不是这部作品的页：没有进会话。
    OtherWork,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IngestOutcome {
    pub status: IngestStatus,
    /// 这一章在会话里的序号（Added / Updated 时有）。
    pub index: Option<usize>,
    pub chapter_count: usize,
    pub tail_next: Option<String>,
}

#[derive(Debug, Default)]
pub struct NovelSession {
    state: SessionState,
}

impl NovelSession {
    pub fn new() -> Self {
        Self {
            state: SessionState {
                kind: SNAPSHOT_TYPE.to_owned(),
                version: SNAPSHOT_VERSION,
                ..Default::default()
            },
        }
    }

    /// 从快照恢复（空字节 = 新会话）。类型 / 版本不对或 JSON 坏了报错。
    pub fn restore(snapshot: &[u8]) -> Result<Self, String> {
        if snapshot.is_empty() {
            return Ok(Self::new());
        }
        let mut state: SessionState =
            serde_json::from_slice(snapshot).map_err(|e| format!("bad snapshot: {e}"))?;
        if state.kind != SNAPSHOT_TYPE {
            return Err(format!("not a web novel snapshot: {}", state.kind));
        }
        if state.version != SNAPSHOT_VERSION {
            return Err(format!("unsupported snapshot version {}", state.version));
        }
        // 存档里的章节可能来自旧版本 / 手改：按 URL 去重一次再重算派生字段。
        let mut seen = HashSet::new();
        state.chapters.retain(|c| seen.insert(canonical(&c.url)));
        let mut session = Self { state };
        session.recompute();
        Ok(session)
    }

    pub fn state(&self) -> &SessionState {
        &self.state
    }

    pub fn snapshot_json(&self) -> Result<Vec<u8>, String> {
        serde_json::to_vec(&self.state).map_err(|e| e.to_string())
    }

    pub fn ingest(&mut self, article: &Article) -> IngestOutcome {
        if article.is_empty() {
            return self.outcome(IngestStatus::Empty, None);
        }
        match &self.state.work_key {
            Some(key) if *key != article.work_key => {
                return self.outcome(IngestStatus::OtherWork, None);
            }
            Some(_) => {}
            None => self.state.work_key = Some(article.work_key.clone()),
        }
        fill(&mut self.state.site_rule, &article.site_rule);
        fill(&mut self.state.work_title, &article.work_title);
        fill(&mut self.state.author, &article.author);
        fill(&mut self.state.lang, &article.lang);
        if article.toc.is_some() {
            self.state.toc = article.toc.clone();
        }

        let meta = ChapterMeta {
            url: article.url.clone(),
            title: article.title.clone(),
            next: article.next.clone(),
            prev: article.prev.clone(),
            chars: article.chars,
            hash: article.content_hash.clone(),
        };
        let key = canonical(&meta.url);
        let existing = self.state.chapters.iter().position(|c| {
            canonical(&c.url) == key || (!meta.hash.is_empty() && c.hash == meta.hash)
        });
        if let Some(i) = existing {
            let old = &mut self.state.chapters[i];
            old.title = meta.title;
            old.chars = meta.chars;
            old.hash = meta.hash;
            if meta.next.is_some() {
                old.next = meta.next;
            }
            if meta.prev.is_some() {
                old.prev = meta.prev;
            }
            self.recompute();
            return self.outcome(IngestStatus::Updated, Some(i));
        }
        let at = self.insertion_point(&meta);
        self.state.chapters.insert(at, meta);
        self.recompute();
        self.outcome(IngestStatus::Added, Some(at))
    }

    fn insertion_point(&self, meta: &ChapterMeta) -> usize {
        let chapters = &self.state.chapters;
        let key = canonical(&meta.url);
        let points_here =
            |link: &Option<String>| link.as_deref().map(canonical) == Some(key.clone());
        if let Some(i) = chapters.iter().position(|c| points_here(&c.next)) {
            return i + 1;
        }
        if let Some(i) = chapters.iter().position(|c| points_here(&c.prev)) {
            return i;
        }
        if let Some(next) = meta.next.as_deref().map(canonical) {
            if let Some(i) = chapters.iter().position(|c| canonical(&c.url) == next) {
                return i;
            }
        }
        if let Some(prev) = meta.prev.as_deref().map(canonical) {
            if let Some(i) = chapters.iter().position(|c| canonical(&c.url) == prev) {
                return i + 1;
            }
        }
        chapters.len()
    }

    fn recompute(&mut self) {
        let have: HashSet<String> = self
            .state
            .chapters
            .iter()
            .map(|c| canonical(&c.url))
            .collect();
        let toc = self.state.toc.as_deref().map(canonical);
        let wanted = |url: &&String| -> bool {
            let key = canonical(url);
            !have.contains(&key) && toc.as_deref() != Some(key.as_str())
        };
        let mut queue: Vec<String> = Vec::new();
        let mut queued: HashSet<String> = HashSet::new();
        for chapter in &self.state.chapters {
            if let Some(next) = chapter.next.as_ref().filter(wanted) {
                if queued.insert(canonical(next)) {
                    queue.push(next.clone());
                }
            }
        }
        let tail_next = self
            .state
            .chapters
            .last()
            .and_then(|c| c.next.as_ref())
            .filter(wanted)
            .cloned();
        self.state.queue = queue;
        self.state.tail_next = tail_next;
    }

    fn outcome(&self, status: IngestStatus, index: Option<usize>) -> IngestOutcome {
        IngestOutcome {
            status,
            index,
            chapter_count: self.state.chapters.len(),
            tail_next: self.state.tail_next.clone(),
        }
    }
}

fn fill(slot: &mut Option<String>, value: &Option<String>) {
    if slot.is_none() {
        if let Some(v) = value {
            if !v.is_empty() {
                *slot = Some(v.clone());
            }
        }
    }
}

/// 链接串 → 章节身份串（比较专用；存档与取页都用原始 URL）。
pub(crate) fn canonical(url: &str) -> String {
    url::Url::parse(url)
        .map(|u| super::links::canonical_url(&u))
        .unwrap_or_else(|_| url.to_owned())
}

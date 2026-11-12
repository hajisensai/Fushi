//! 存量带盐 ID → 规范 ID 的别名判定（docs/specs/2026-11-11-srs-generation-break.md §5.3）。
//!
//! 输入是一个集合的「证据」（[Evidence]：身份记录里的自然键、定义与牌组寄存器的历史值、观察到的卡 / 日志 / 写入者，
//! 加上这个集合的盐集合），输出是别名表（[Aliases]）。纯函数：只看参数，不读库、不看到达顺序；证据多了就重算。
//!
//! 判定只有一种依据：**按规则重算出的哈希与观察到的 ID 相等**。验不上的 ID 规范 ID 就是它自己（不合并、不丢）。
//!
//! 「别名类」= 同一个规范 ID 下的全部 ID。自然键验上的实体，别名类里含它在**每个盐下**的值（[rules] 的带盐规则），
//! 不管那个值在集合里出现过没有：旧并入把另一个 uid 的行并进来后删掉了原行，只留下
//! `v5(NS, profile-merge/<目标 uid>/<原 ID>)` 这样的兜底 ID，原 ID 自己不在集合里，但能由「自然键 × 盐」算出来。
//!
//! 约定：
//! - ID 一律是规范形状的 UUID（[strict_id]：小写、带连字符——存储层压成 16 字节的那一种）。别的形状的 ID 文本
//!   （大写、无连字符、非 UUID）在存储层是另一个值，不要解析进来；它们没有别名，规范 ID 是它自己。
//! - 盐集合由调用方给，**各设备必须给同一个集合**，否则各自算出的规范 ID 不同。它不能取自某台设备本机才有的
//!   记录（见模块说明里给 G9 的要点）。
//! - 写入者改名的归并比 ID 多一道条件：哈希验上之外，还要有「是同一套 seq」的正面证据（[WriterHow]）。

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use crate::sync2::id::{Id, Key};

use super::rules;

/// 规范形状（小写、带连字符）的 UUID 文本 → ID；别的形状一律不认（与 `Key::of`、存储层的 `srs_id` 同一个判据）。
pub fn strict_id(text: &str) -> Option<Id> {
    match Key::of(text) {
        Key::Uuid(id) => Some(id),
        Key::Text(_) => None,
    }
}

/// 代码里的一种内置笔记类型（`lapis`、`fushi_card`）：key、字段的派生种子、模板名。
#[derive(Clone, Debug, Default)]
pub struct BuiltinNoteType {
    pub key: String,
    pub field_seeds: Vec<String>,
    pub template_keys: Vec<String>,
}

/// 一个字段 / 模板定义：`fieldDef/<id>`、`tmplDef/<id>` 键里的 ID，与这个寄存器**全部历史值**里出现过的
/// `ankiNum` / `name`。
#[derive(Clone, Debug, Default)]
pub struct DefEv {
    pub id: Id,
    pub anki_nums: Vec<i64>,
    pub names: Vec<String>,
}

/// 一条笔记类型身份记录与它的定义史。
#[derive(Clone, Debug, Default)]
pub struct NoteTypeEv {
    pub id: Id,
    pub anki_num: Option<i64>,
    /// 填空类型：卡的序号要枚举（[Limits::cloze_ords]、[NoteEv::cloze_ords]）；普通类型只有 0。
    pub cloze: bool,
    pub fields: Vec<DefEv>,
    pub templates: Vec<DefEv>,
}

/// 一条笔记身份记录，加上 `noteType` 寄存器的全部历史值（含身份记录里的 `noteTypeId`）。
#[derive(Clone, Debug, Default)]
pub struct NoteEv {
    pub id: Id,
    pub guid: Option<String>,
    pub note_types: Vec<Id>,
    /// 这条笔记的字段史里出现过的填空序号（[Limits::cloze_ords] 以内的不用列，总会试）。
    pub cloze_ords: Vec<i64>,
}

/// 一个牌组：`name` 与 `parent` 两个寄存器的全部历史值（「没有父牌组」不用列，总会试：顶层建的牌组没有
/// `parent` 修改记录）。
#[derive(Clone, Debug, Default)]
pub struct DeckEv {
    pub id: Id,
    pub names: Vec<String>,
    pub parents: Vec<Id>,
}

/// 一条日志的身份相关部分。
#[derive(Clone, Debug, Default)]
pub struct LogEv {
    pub id: Id,
    pub card: Id,
    /// Anki 导入日志的 revlog id。
    pub anki_revlog_id: Option<i64>,
    /// 导入锚点的发生时刻（只有锚点填）。
    pub anchor_at: Option<i64>,
    /// undo 点名的日志。
    pub revokes: Option<Id>,
}

/// 一条带旧 dot 的修改记录：写入者内的序号，与它的 HLC 物理时刻、计数。
/// 「同 seq、同物理时刻与计数」= 同一条记录（旧并入 `_Writers.alias` 用的同一个判据）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Dot {
    pub seq: u64,
    pub physical: i64,
    pub counter: i64,
}

/// 一个在操作里出现过的写入者名字（修改记录的 dot、HLC、旧上下文的键）与它名下的记录。
#[derive(Clone, Debug, Default)]
pub struct WriterEv {
    pub name: String,
    pub dots: Vec<Dot>,
}

/// 一个集合的证据。各项都是集合语义：顺序、重复都不影响结果；同一个 ID 的多条证据取并集。
#[derive(Clone, Debug, Default)]
pub struct Evidence {
    /// 这个集合里出现过的 profile uid（当前的、退役的、并入带来的）。
    pub salts: Vec<String>,
    pub builtins: Vec<BuiltinNoteType>,
    pub note_types: Vec<NoteTypeEv>,
    pub notes: Vec<NoteEv>,
    pub decks: Vec<DeckEv>,
    /// 观察到的卡 ID（卡缓存、card 类修改记录的实体、`historyFrom/<id>` 键……）。日志里的卡不用再列。
    pub cards: Vec<Id>,
    pub logs: Vec<LogEv>,
    pub writers: Vec<WriterEv>,
    /// 只当「最初的写入者」候选的名字（设备 ID 之类没在操作里出现过的）。
    pub writer_hints: Vec<String>,
    /// 其余观察到的 ID（profile 级设置实体……）：只参与兜底 ID 的正向计算。
    pub other_ids: Vec<Id>,
}

/// 枚举的上限。
#[derive(Clone, Debug)]
pub struct Limits {
    /// 牌组备选序号试到几（旧并入的验算也只试到 8；新建牌组时没有上限，超过的验不上）。
    pub deck_alternates: u32,
    /// 一个牌组最多多少个候选全名；超过就不验（[Why::TooManyCandidates]）。
    pub deck_paths: usize,
    /// 父牌组链最多追多深。
    pub deck_depth: usize,
    /// 填空类型的卡序号枚举 `0..=这个数`（导入的是 Anki 的 ord + 1，Fushi 自己解析的从 1 起、没有上限；
    /// 更大的由 [NoteEv::cloze_ords] 给）。
    pub cloze_ords: i64,
    /// 「认出兜底别名 → 别名类变大 → 再枚举」最多几轮。
    pub rounds: usize,
    /// 改名写入者最多追几跳（中间那个名字不在集合里的链式并入）。
    pub writer_hops: usize,
    /// 自然键验上的实体是否把「每个盐下的值」都算进别名类（见文件头）。关掉 = 只认集合里出现过的 ID，
    /// 只给探针做对照用。
    pub virtual_aliases: bool,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            deck_alternates: 8,
            deck_paths: 4096,
            deck_depth: 32,
            cloze_ords: 500,
            rounds: 8,
            writer_hops: 3,
            virtual_aliases: true,
        }
    }
}

/// 一个 ID 是怎么认出来的。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum How {
    /// 本来就是规范规则的值。
    Canonical,
    /// 带盐的根规则验上（笔记、笔记类型、牌组、内置默认牌组、profile 级实体）；`salt` 是 [Aliases::salts] 的下标。
    Salted { salt: u16 },
    /// 由父 ID 按公式派生验上（字段、模板、卡、导入日志、锚点、补的 undo）。父没有别名时规范 ID 等于它自己。
    Derived,
    /// 旧并入的兜底 ID：`v5(NS, profile-merge/<盐>/<X>)` 验上，规范 ID = X 的规范 ID。
    Fallback { salt: u16 },
    /// 验不上：规范 ID 就是它自己。
    Unverified(Why),
    /// 证据里没出现过、也算不出来的 ID。
    Unknown,
}

/// 验不上的原因。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Why {
    /// 证据里没有它的自然键（身份记录缺 guid / ankiNum、定义没有 ankiNum 也没有名字、牌组没有名字）。
    NoNaturalKey,
    /// 有自然键 / 有候选，但没有一个算得出它。
    NoMatch,
    /// 候选太多没有枚举（[Limits::deck_paths]）。
    TooManyCandidates,
    /// 随机 ID（UUIDv7）：不是派生出来的，本来就不带盐。
    NotDerived,
    /// 两条规则给了它两个不同的规范 ID（只可能是哈希碰撞）：哪个都不取。
    Conflict,
}

/// 一个写入者名字是怎么判的。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum WriterHow {
    /// 不是 `merged-…` 形状的名字。
    Plain,
    /// 哈希验上，且它与最初的写入者在这个集合里有同 seq 的同一条记录、没有同 seq 的不同记录：归到最初的写入者。
    Resolved,
    /// 哈希验上，但同一个 seq 上是另一条记录：同一个写入者名字在两个 uid 下各有一套 seq（v1 写入者名是
    /// `设备#代次`，序号按 profile 记），归过去会让两条不同的修改记录同 dot。不归。
    DotsDiffer,
    /// 哈希验上，但没有「是同一套 seq」的正面证据（最初的写入者或它自己在这个集合里没有记录，或没有一个 seq
    /// 重合）。不归；另一边的记录到了再重算。
    Unproven,
    /// `merged-…` 形状，哈希验不上。
    Unverified,
}

#[derive(Clone, Copy, Debug)]
struct Entry {
    canonical: Id,
    how: How,
    /// 兜底 ID 归到的那个观察到的 ID：它的规范 ID 可能在后面才定下来（日志要等卡定了才算），收尾时沿着它再取一次。
    via: Option<Id>,
}

#[derive(Clone, Debug)]
struct WriterEntry {
    origin: String,
    how: WriterHow,
}

/// 别名表。
#[derive(Clone, Debug, Default)]
pub struct Aliases {
    salts: Vec<String>,
    map: HashMap<Id, Entry>,
    writers: HashMap<String, WriterEntry>,
    conflicts: usize,
    rounds: usize,
    hashes: u64,
}

impl Aliases {
    /// [id] 的规范 ID；不认识或验不上的就是它自己。
    pub fn canonical(&self, id: &Id) -> Id {
        self.map.get(id).map_or(*id, |e| e.canonical)
    }

    /// [id] 是怎么认出来的。
    pub fn how(&self, id: &Id) -> How {
        self.map.get(id).map_or(How::Unknown, |e| e.how)
    }

    /// 写入者 [w] 的规范名字：[WriterHow::Resolved] 的归到最初的写入者，其余是它自己。
    ///
    /// 用它的人要把一条修改记录里的三处一起换：dot 的写入者、HLC 的写入者、旧上下文的键（内核要求修改记录的 ID
    /// 等于 `edit/<dot 写入者>/<seq>`，registers.rs）。
    pub fn canonical_writer<'a>(&self, w: &'a str) -> Cow<'a, str> {
        match self.writers.get(w) {
            Some(e) if e.how == WriterHow::Resolved => Cow::Owned(e.origin.clone()),
            _ => Cow::Borrowed(w),
        }
    }

    /// 写入者 [w] 是怎么判的。
    pub fn writer_how(&self, w: &str) -> WriterHow {
        match self.writers.get(w) {
            Some(e) => e.how,
            None if parse_merged(w).is_some() => WriterHow::Unverified,
            None => WriterHow::Plain,
        }
    }

    /// 哈希验上的最初写入者（不管最后归没归过去）。
    pub fn writer_origin(&self, w: &str) -> Option<&str> {
        self.writers.get(w).map(|e| e.origin.as_str())
    }

    /// 修改记录 [id] 的规范 ID：[id] 确实是 `(writer, seq)` 按公式派生的、且写入者归到了别的名字时，换成按规范
    /// 写入者算的值；否则是它自己。
    pub fn canonical_edit(&self, id: &Id, writer: &str, seq: u64) -> Id {
        match self.writers.get(writer) {
            Some(e) if e.how == WriterHow::Resolved && rules::field_edit(writer, seq) == *id => {
                rules::field_edit(&e.origin, seq)
            }
            _ => *id,
        }
    }

    /// 盐（排序去重后）；[How::Salted] / [How::Fallback] 的 `salt` 是它的下标。
    pub fn salts(&self) -> &[String] {
        &self.salts
    }

    /// 归到了最初写入者的名字：(存量名字, 规范名字)，按存量名字排序。
    pub fn merged_writers(&self) -> Vec<(&str, &str)> {
        let mut v: Vec<(&str, &str)> = self
            .writers
            .iter()
            .filter(|(_, e)| e.how == WriterHow::Resolved)
            .map(|(a, e)| (a.as_str(), e.origin.as_str()))
            .collect();
        v.sort();
        v
    }

    /// 同一个 ID 被两条规则给出两个不同规范 ID 的次数（只可能是哈希碰撞；正常是 0）。
    pub fn conflicts(&self) -> usize {
        self.conflicts
    }

    /// 枚举跑了几轮。
    pub fn rounds(&self) -> usize {
        self.rounds
    }

    /// 一共算了多少次 UUIDv5（成本的度量）。
    pub fn hashes(&self) -> u64 {
        self.hashes
    }

    /// 表里的条目数（观察到的 ID 加上算得出的根 / 定义别名）。
    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum DefKey {
    Num(i64),
    Name(String),
}

#[derive(Clone, Debug, Default)]
struct NtClass {
    /// 验上的自然键；None = 没验上，类里只有它自己。
    anki_num: Option<i64>,
    /// 观察到、归进这个类的身份记录 ID。
    members: BTreeSet<Id>,
    cloze: bool,
    fields: BTreeSet<DefKey>,
    templates: BTreeSet<DefKey>,
    /// 观察到的定义 ID → 证据里有没有它的自然键（验不上的也是一个模板 / 字段，卡要用它）。
    seen_fields: BTreeMap<Id, bool>,
    seen_templates: BTreeMap<Id, bool>,
}

#[derive(Clone, Debug, Default)]
struct NoteClass {
    guid: Option<String>,
    /// 观察到、归进这个类的身份记录 ID。
    members: BTreeSet<Id>,
    /// 笔记类型史（原样的 ID，用时再归到类）。
    note_types: BTreeSet<Id>,
    cloze_ords: BTreeSet<i64>,
}

#[derive(Clone, Debug)]
struct DefClass {
    canonical: Id,
    aliases: Vec<Id>,
}

/// 兜底 ID 归到的那个 ID 属于哪种类：决定别名类变大后要不要再枚举。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// 笔记类型、字段 / 模板、笔记：它的别名会派生出别的 ID。
    Branch,
    /// 牌组、卡、日志、其它：没有东西由它派生。
    Leaf,
}

struct Resolver<'a> {
    ev: &'a Evidence,
    limits: &'a Limits,
    out: Aliases,
    salt_ids: Vec<Option<Id>>,
    nt: BTreeMap<Id, NtClass>,
    notes: BTreeMap<Id, NoteClass>,
    /// 认出来的兜底别名：类的规范 ID → 多出来的别名。
    extra: BTreeMap<Id, BTreeSet<Id>>,
    /// 牌组、内置牌组、profile 实体：算一次就不变的别名（别名, 规范）。
    static_aliases: Vec<(Id, Id)>,
    observed: HashSet<Id>,
    observed_cards: HashSet<Id>,
    /// 只当兜底 ID 的「原 ID」试、不派生别的东西的观察到的 ID（卡、日志、牌组、其它），排好序。
    leaves: Vec<Id>,
    why: HashMap<Id, Why>,
}

/// 一轮里新认出的兜底别名：(别名, 它归到的类的规范 ID——叶子上是 None，收尾时沿 `via` 取, 种类)。
type Fresh = Vec<(Id, Option<Id>, Kind)>;

/// 由证据算别名表。
pub fn resolve(ev: &Evidence, limits: &Limits) -> Aliases {
    let mut r = Resolver::new(ev, limits);
    r.root_note_types();
    r.root_notes();
    r.decks();
    r.profile_entities();
    r.rounds();
    r.flatten();
    r.derived_logs();
    r.flatten();
    r.repair_undos();
    r.flatten();
    r.unverified();
    r.writers();
    r.out
}

impl<'a> Resolver<'a> {
    fn new(ev: &'a Evidence, limits: &'a Limits) -> Self {
        let salts: Vec<String> = ev
            .salts
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let salt_ids = salts.iter().map(|s| strict_id(s)).collect();
        let mut observed: HashSet<Id> = HashSet::new();
        let mut observed_cards: HashSet<Id> = HashSet::new();
        for t in &ev.note_types {
            observed.insert(t.id);
            observed.extend(t.fields.iter().map(|d| d.id));
            observed.extend(t.templates.iter().map(|d| d.id));
        }
        observed.extend(ev.notes.iter().map(|n| n.id));
        observed.extend(ev.decks.iter().map(|d| d.id));
        observed.extend(ev.other_ids.iter().copied());
        observed_cards.extend(ev.cards.iter().copied());
        let mut leaves: Vec<Id> = Vec::new();
        for l in &ev.logs {
            observed.insert(l.id);
            observed_cards.insert(l.card);
            leaves.push(l.id);
            if let Some(r) = l.revokes {
                observed.insert(r);
                leaves.push(r);
            }
        }
        observed.extend(observed_cards.iter().copied());
        leaves.extend(observed_cards.iter().copied());
        leaves.extend(ev.decks.iter().map(|d| d.id));
        leaves.extend(ev.other_ids.iter().copied());
        leaves.sort_unstable();
        leaves.dedup();
        Resolver {
            ev,
            limits,
            out: Aliases {
                salts,
                ..Aliases::default()
            },
            salt_ids,
            nt: BTreeMap::new(),
            notes: BTreeMap::new(),
            extra: BTreeMap::new(),
            static_aliases: Vec::new(),
            observed,
            observed_cards,
            leaves,
            why: HashMap::new(),
        }
    }

    /// 记下 [id] 的规范 ID。已经记过的不改；记过的规范 ID 与这次不同（哈希碰撞）就记一次冲突，这个 ID 按验不上
    /// 处理（规范 ID 是它自己），不在两个里挑。返回是不是新认出来的。
    fn set(&mut self, id: Id, canonical: Id, how: How) -> bool {
        match self.out.map.get_mut(&id) {
            None => {
                self.out.map.insert(
                    id,
                    Entry {
                        canonical,
                        how,
                        via: None,
                    },
                );
                true
            }
            Some(e) => {
                let conflict = How::Unverified(Why::Conflict);
                if e.via.is_none() && e.canonical != canonical && e.how != conflict {
                    self.out.conflicts += 1;
                    *e = Entry {
                        canonical: id,
                        how: conflict,
                        via: None,
                    };
                }
                false
            }
        }
    }

    /// 根规则的验算：[id] 是不是 `rule(盐)` 的值。返回 (规范 ID, 怎么认的)。
    fn rooted(&mut self, id: &Id, rule: impl Fn(rules::Salt<'_>) -> Id) -> Option<(Id, How)> {
        let canonical = rule(rules::CANONICAL);
        self.out.hashes += 1;
        if *id == canonical {
            return Some((canonical, How::Canonical));
        }
        for i in 0..self.out.salts.len() {
            self.out.hashes += 1;
            if rule(Some(self.out.salts[i].as_str())) == *id {
                return Some((canonical, How::Salted { salt: i as u16 }));
            }
        }
        None
    }

    /// 根规则算得出的别名：规范值，加上（[Limits::virtual_aliases]）每个盐下的值。
    fn rooted_aliases(&mut self, rule: impl Fn(rules::Salt<'_>) -> Id) -> Vec<(Id, How)> {
        let mut v = vec![(rule(rules::CANONICAL), How::Canonical)];
        self.out.hashes += 1;
        if self.limits.virtual_aliases {
            for i in 0..self.out.salts.len() {
                self.out.hashes += 1;
                v.push((
                    rule(Some(self.out.salts[i].as_str())),
                    How::Salted { salt: i as u16 },
                ));
            }
        }
        v
    }

    /// 类 [canonical] 的全部别名 = 算得出的 ∪ 观察到归进来的 ∪ 认出来的兜底别名。排序去重。
    fn class_aliases(&self, canonical: &Id, computed: Vec<Id>, members: &BTreeSet<Id>) -> Vec<Id> {
        let mut v = computed;
        v.push(*canonical);
        v.extend(members.iter().copied());
        if let Some(x) = self.extra.get(canonical) {
            v.extend(x.iter().copied());
        }
        v.sort_unstable();
        v.dedup();
        v
    }

    // ---------------------------------------------------------------- 笔记类型（根）

    fn root_note_types(&mut self) {
        #[derive(Default)]
        struct Seen<'e> {
            nums: BTreeSet<i64>,
            cloze: bool,
            fields: Vec<&'e DefEv>,
            templates: Vec<&'e DefEv>,
        }
        let ev = self.ev;
        for b in &ev.builtins {
            let n = rules::builtin_note_type_anki_num(&b.key);
            let c = self
                .nt
                .entry(rules::note_type(rules::CANONICAL, n))
                .or_default();
            c.anki_num = Some(n);
            for seed in &b.field_seeds {
                c.fields
                    .insert(DefKey::Num(rules::builtin_field_anki_num(&b.key, seed)));
            }
            for t in &b.template_keys {
                c.templates
                    .insert(DefKey::Num(rules::builtin_template_anki_num(&b.key, t)));
            }
        }
        // 同一个 ID 的多条证据先并起来。
        let mut seen: BTreeMap<Id, Seen<'a>> = BTreeMap::new();
        for t in &ev.note_types {
            let s = seen.entry(t.id).or_default();
            s.nums.extend(t.anki_num);
            s.cloze |= t.cloze;
            s.fields.extend(&t.fields);
            s.templates.extend(&t.templates);
        }
        for (id, s) in seen {
            let mut verified: Option<(i64, Id, How)> = None;
            for n in &s.nums {
                if let Some((canonical, how)) = self.rooted(&id, |salt| rules::note_type(salt, *n))
                {
                    verified = Some((*n, canonical, how));
                    break;
                }
            }
            let class = match verified {
                Some((n, canonical, how)) => {
                    self.set(id, canonical, how);
                    self.nt.entry(canonical).or_default().anki_num = Some(n);
                    canonical
                }
                None => {
                    let why = if s.nums.is_empty() {
                        Why::NoNaturalKey
                    } else {
                        Why::NoMatch
                    };
                    self.why.insert(id, why);
                    id
                }
            };
            let c = self.nt.entry(class).or_default();
            c.members.insert(id);
            c.cloze |= s.cloze;
            for (defs, keys, seen_defs) in [
                (&s.fields, &mut c.fields, &mut c.seen_fields),
                (&s.templates, &mut c.templates, &mut c.seen_templates),
            ] {
                for d in defs {
                    let has_key = !d.anki_nums.is_empty() || !d.names.is_empty();
                    *seen_defs.entry(d.id).or_default() |= has_key;
                    keys.extend(d.anki_nums.iter().map(|n| DefKey::Num(*n)));
                    keys.extend(d.names.iter().map(|s| DefKey::Name(s.clone())));
                }
            }
        }
        for c in self.nt.values() {
            for (id, has_key) in c.seen_fields.iter().chain(&c.seen_templates) {
                if !has_key {
                    self.why.insert(*id, Why::NoNaturalKey);
                }
            }
        }
    }

    // ---------------------------------------------------------------- 笔记（根）

    fn root_notes(&mut self) {
        #[derive(Default)]
        struct Seen<'e> {
            guids: BTreeSet<&'e str>,
            note_types: BTreeSet<Id>,
            cloze_ords: BTreeSet<i64>,
        }
        let ev = self.ev;
        let mut seen: BTreeMap<Id, Seen<'a>> = BTreeMap::new();
        for n in &ev.notes {
            let s = seen.entry(n.id).or_default();
            s.guids.extend(n.guid.as_deref());
            s.note_types.extend(n.note_types.iter().copied());
            s.cloze_ords.extend(n.cloze_ords.iter().copied());
        }
        for (id, s) in seen {
            let mut verified: Option<(&str, Id, How)> = None;
            for g in &s.guids {
                if let Some((canonical, how)) = self.rooted(&id, |salt| rules::note(salt, g)) {
                    verified = Some((*g, canonical, how));
                    break;
                }
            }
            let class = match verified {
                Some((g, canonical, how)) => {
                    self.set(id, canonical, how);
                    self.notes.entry(canonical).or_default().guid = Some(g.to_owned());
                    canonical
                }
                None => {
                    let why = if s.guids.is_empty() {
                        Why::NoNaturalKey
                    } else {
                        Why::NoMatch
                    };
                    self.why.insert(id, why);
                    id
                }
            };
            let c = self.notes.entry(class).or_default();
            c.members.insert(id);
            c.note_types.extend(s.note_types);
            c.cloze_ords.extend(s.cloze_ords);
        }
    }

    // ---------------------------------------------------------------- 牌组

    /// [id] 的候选全名：自己名字的每个历史值 ×（顶层 ∪ 每个历史父牌组的每个候选全名）。None = 超过上限。
    fn deck_paths(
        &self,
        id: &Id,
        decks: &BTreeMap<Id, (BTreeSet<&'a str>, BTreeSet<Id>)>,
        stack: &mut Vec<Id>,
    ) -> Option<BTreeSet<String>> {
        let (names, parents) = decks.get(id)?;
        let mut out: BTreeSet<String> = names.iter().map(|n| (*n).to_owned()).collect();
        if stack.len() >= self.limits.deck_depth {
            return Some(out);
        }
        stack.push(*id);
        let mut overflow = false;
        'parents: for p in parents {
            if stack.contains(p) || !decks.contains_key(p) {
                continue;
            }
            let Some(up) = self.deck_paths(p, decks, stack) else {
                overflow = true;
                break;
            };
            for pp in &up {
                for n in names {
                    out.insert(format!("{pp}::{n}"));
                    if out.len() > self.limits.deck_paths {
                        overflow = true;
                        break 'parents;
                    }
                }
            }
        }
        stack.pop();
        (!overflow && out.len() <= self.limits.deck_paths).then_some(out)
    }

    fn decks(&mut self) {
        let ev = self.ev;
        let mut decks: BTreeMap<Id, (BTreeSet<&'a str>, BTreeSet<Id>)> = BTreeMap::new();
        for d in &ev.decks {
            let e = decks.entry(d.id).or_default();
            e.0.extend(d.names.iter().map(String::as_str));
            e.1.extend(d.parents.iter().copied());
        }
        let ids: Vec<Id> = decks.keys().copied().collect();
        for id in ids {
            if let Some((canonical, how)) = self.rooted(&id, rules::builtin_default_deck) {
                self.set(id, canonical, how);
                continue;
            }
            if decks[&id].0.is_empty() {
                self.why.insert(id, Why::NoNaturalKey);
                continue;
            }
            let Some(paths) = self.deck_paths(&id, &decks, &mut Vec::new()) else {
                self.why.insert(id, Why::TooManyCandidates);
                continue;
            };
            let mut found: Option<(Id, How, String, u32)> = None;
            'paths: for p in &paths {
                for n in 0..=self.limits.deck_alternates {
                    let hit = if n == 0 {
                        self.rooted(&id, |s| rules::deck(s, p))
                    } else {
                        self.rooted(&id, |s| rules::deck_alternate(s, p, n))
                    };
                    if let Some((canonical, how)) = hit {
                        found = Some((canonical, how, p.clone(), n));
                        break 'paths;
                    }
                }
            }
            match found {
                Some((canonical, how, path, n)) => {
                    self.set(id, canonical, how);
                    let all = if n == 0 {
                        self.rooted_aliases(|s| rules::deck(s, &path))
                    } else {
                        self.rooted_aliases(|s| rules::deck_alternate(s, &path, n))
                    };
                    for (a, how) in all {
                        self.set(a, canonical, how);
                        self.static_aliases.push((a, canonical));
                    }
                }
                None => {
                    self.why.insert(id, Why::NoMatch);
                }
            }
        }
        let canonical = rules::builtin_default_deck(rules::CANONICAL);
        for (a, how) in self.rooted_aliases(rules::builtin_default_deck) {
            self.set(a, canonical, how);
            self.static_aliases.push((a, canonical));
        }
    }

    // ---------------------------------------------------------------- profile 级设置实体

    /// 存量里 profile 级设置实体的 ID 就是 uid 本身：每个盐都是规范实体的别名。
    fn profile_entities(&mut self) {
        let canonical = rules::profile_entity();
        self.out.hashes += 1;
        self.set(canonical, canonical, How::Canonical);
        self.static_aliases.push((canonical, canonical));
        for i in 0..self.salt_ids.len() {
            let Some(id) = self.salt_ids[i] else {
                continue;
            };
            if self.limits.virtual_aliases || self.observed.contains(&id) {
                self.set(id, canonical, How::Salted { salt: i as u16 });
                self.static_aliases.push((id, canonical));
            }
        }
    }

    // ---------------------------------------------------------------- 枚举 + 兜底 ID

    /// [x] 在每个盐下的兜底 ID 若被观察到，就是 [x] 的别名。[canonical] 是 [x] 所在类的规范 ID；叶子上传 None
    /// （它自己的规范 ID 可能后面才定，收尾时沿 `via` 取）。
    fn try_fallback(
        &mut self,
        x: &Id,
        canonical: Option<&Id>,
        kind: Kind,
        fresh: &mut Fresh,
        dirty: &mut bool,
    ) {
        let text = x.text();
        for i in 0..self.out.salts.len() {
            let f = rules::merge_fallback(&self.out.salts[i], &text);
            self.out.hashes += 1;
            if f == *x || !self.observed.contains(&f) || self.out.map.contains_key(&f) {
                continue;
            }
            self.out.map.insert(
                f,
                Entry {
                    canonical: canonical.copied().unwrap_or(*x),
                    how: How::Fallback { salt: i as u16 },
                    via: canonical.is_none().then_some(*x),
                },
            );
            fresh.push((f, canonical.copied(), kind));
            if let (Kind::Branch, Some(c)) = (kind, canonical) {
                self.extra.entry(*c).or_default().insert(f);
                *dirty = true;
            }
        }
    }

    fn rounds(&mut self) {
        let mut fresh: Fresh = Vec::new();
        let mut dirty = true;
        while self.out.rounds < self.limits.rounds.max(1) {
            self.out.rounds += 1;
            let mut next: Fresh = Vec::new();
            let mut next_dirty = false;
            if dirty {
                self.full_pass(&mut next, &mut next_dirty);
            } else {
                // 上一轮只认出了叶子上的兜底 ID：只需要再试它们自己的兜底（链式并入 A→B→C）。
                for (f, canonical, kind) in std::mem::take(&mut fresh) {
                    self.try_fallback(&f, canonical.as_ref(), kind, &mut next, &mut next_dirty);
                }
            }
            if next.is_empty() && !next_dirty {
                break;
            }
            fresh = next;
            dirty = next_dirty;
        }
    }

    fn full_pass(&mut self, fresh: &mut Fresh, dirty: &mut bool) {
        // 1. 笔记类型的别名。
        let classes: Vec<Id> = self.nt.keys().copied().collect();
        let mut nt_aliases: BTreeMap<Id, Vec<Id>> = BTreeMap::new();
        let mut nt_member: HashMap<Id, Id> = HashMap::new();
        for canonical in &classes {
            let (anki_num, members) = {
                let c = &self.nt[canonical];
                (c.anki_num, c.members.clone())
            };
            let computed: Vec<Id> = match anki_num {
                Some(n) => {
                    let all = self.rooted_aliases(|s| rules::note_type(s, n));
                    for (a, how) in &all {
                        self.set(*a, *canonical, *how);
                    }
                    all.into_iter().map(|(a, _)| a).collect()
                }
                None => Vec::new(),
            };
            let aliases = self.class_aliases(canonical, computed, &members);
            for a in &aliases {
                nt_member.insert(*a, *canonical);
                self.try_fallback(a, Some(canonical), Kind::Branch, fresh, dirty);
            }
            nt_aliases.insert(*canonical, aliases);
        }

        // 2. 字段 / 模板。先把每个类里每个自然键在笔记类型每个别名下的值都认了，再看剩下的：验不上的观察到的
        //    定义各自成类（它也是一个模板，卡要用它）。
        let none = BTreeSet::new();
        let mut templates: BTreeMap<Id, Vec<DefClass>> = BTreeMap::new();
        for class in &classes {
            let c = self.nt[class].clone();
            let aliases = &nt_aliases[class];
            for is_field in [true, false] {
                let keys = if is_field { &c.fields } else { &c.templates };
                for key in keys {
                    let rule = |nt: &Id| match (key, is_field) {
                        (DefKey::Num(n), true) => rules::field(nt, *n),
                        (DefKey::Num(n), false) => rules::template(nt, *n),
                        (DefKey::Name(s), true) => rules::field_by_name(nt, s),
                        (DefKey::Name(s), false) => rules::template_by_name(nt, s),
                    };
                    let canonical = rule(class);
                    let computed: Vec<Id> = aliases.iter().map(&rule).collect();
                    self.out.hashes += computed.len() as u64 + 1;
                    let all = self.class_aliases(&canonical, computed, &none);
                    for a in &all {
                        self.set(*a, canonical, How::Derived);
                        self.try_fallback(a, Some(&canonical), Kind::Branch, fresh, dirty);
                    }
                    if !is_field {
                        templates.entry(*class).or_default().push(DefClass {
                            canonical,
                            aliases: all,
                        });
                    }
                }
            }
        }
        for class in &classes {
            let c = self.nt[class].clone();
            for is_field in [true, false] {
                let seen = if is_field {
                    &c.seen_fields
                } else {
                    &c.seen_templates
                };
                for id in seen.keys() {
                    if self.out.map.contains_key(id) {
                        continue;
                    }
                    let all = self.class_aliases(id, Vec::new(), &none);
                    for a in &all {
                        self.try_fallback(a, Some(id), Kind::Branch, fresh, dirty);
                    }
                    if !is_field {
                        templates.entry(*class).or_default().push(DefClass {
                            canonical: *id,
                            aliases: all,
                        });
                    }
                }
            }
        }

        // 3. 笔记的别名；4. 卡：笔记别名 × 模板别名 × 序号。候选不存表，只与观察到的卡求交、再试它的兜底 ID。
        let note_classes: Vec<Id> = self.notes.keys().copied().collect();
        let base_ords: Vec<i64> = (0..=self.limits.cloze_ords.max(0)).collect();
        for canonical in &note_classes {
            let n = self.notes[canonical].clone();
            let computed: Vec<Id> = match &n.guid {
                Some(g) => {
                    let all = self.rooted_aliases(|s| rules::note(s, g));
                    for (a, how) in &all {
                        self.set(*a, *canonical, *how);
                    }
                    all.into_iter().map(|(a, _)| a).collect()
                }
                None => Vec::new(),
            };
            let aliases = self.class_aliases(canonical, computed, &n.members);
            for a in &aliases {
                self.try_fallback(a, Some(canonical), Kind::Branch, fresh, dirty);
            }
            let types: BTreeSet<Id> = n
                .note_types
                .iter()
                .map(|t| nt_member.get(t).copied().unwrap_or(*t))
                .collect();
            let extra_ords: Vec<i64> = n
                .cloze_ords
                .iter()
                .copied()
                .filter(|o| *o < 0 || *o > self.limits.cloze_ords)
                .collect();
            for t in &types {
                let Some(defs) = templates.get(t) else {
                    continue;
                };
                let cloze = self.nt[t].cloze;
                let ords: &[i64] = if cloze { &base_ords } else { &NO_CLOZE };
                let more: &[i64] = if cloze { &extra_ords } else { &[] };
                for d in defs {
                    for ord in ords.iter().chain(more).copied() {
                        let card_canonical = rules::card(canonical, &d.canonical, ord);
                        self.out.hashes += 1;
                        for a in &aliases {
                            for tpl in &d.aliases {
                                let c = rules::card(a, tpl, ord);
                                self.out.hashes += 1;
                                let seen = self.observed_cards.contains(&c);
                                if seen {
                                    self.set(c, card_canonical, How::Derived);
                                }
                                if seen || self.limits.virtual_aliases {
                                    self.try_fallback(
                                        &c,
                                        Some(&card_canonical),
                                        Kind::Leaf,
                                        fresh,
                                        dirty,
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }

        // 5. 牌组 / 内置牌组 / profile 实体的别名（算好的）。
        for i in 0..self.static_aliases.len() {
            let (a, canonical) = self.static_aliases[i];
            self.try_fallback(&a, Some(&canonical), Kind::Leaf, fresh, dirty);
        }

        // 6. 观察到的叶子（卡、日志、牌组、其它）自己当原 ID。
        for i in 0..self.leaves.len() {
            let x = self.leaves[i];
            self.try_fallback(&x, None, Kind::Leaf, fresh, dirty);
        }
    }

    /// 叶子上的兜底别名：规范 ID 取它归到的那个 ID 此刻的规范 ID（沿 `via` 走到头）。
    fn flatten(&mut self) {
        let mut todo: Vec<Id> = self
            .out
            .map
            .iter()
            .filter(|(_, e)| e.via.is_some())
            .map(|(k, _)| *k)
            .collect();
        todo.sort_unstable();
        for id in todo {
            let mut cur = id;
            let mut steps = 0usize;
            let canonical = loop {
                match self.out.map.get(&cur) {
                    Some(Entry { via: Some(v), .. }) if steps < 64 => {
                        cur = *v;
                        steps += 1;
                    }
                    Some(e) => break e.canonical,
                    None => break cur,
                }
            };
            if let Some(e) = self.out.map.get_mut(&id) {
                e.canonical = canonical;
            }
        }
    }

    // ---------------------------------------------------------------- 日志

    /// 导入日志 / 锚点：ID 确实是「日志里记的卡 + revlog id / 锚点时刻」按公式派生的，规范 ID 就按规范卡重算。
    fn derived_logs(&mut self) {
        let ev = self.ev;
        for l in &ev.logs {
            if self.out.map.contains_key(&l.id) {
                continue;
            }
            self.out.hashes += 2;
            let card = self.out.canonical(&l.card);
            let canonical = match (l.anki_revlog_id, l.anchor_at) {
                (Some(a), _) if rules::imported_revlog(&l.card, a) == l.id => {
                    rules::imported_revlog(&card, a)
                }
                (_, Some(at)) if rules::import_anchor(&l.card, at) == l.id => {
                    rules::import_anchor(&card, at)
                }
                _ => continue,
            };
            self.set(l.id, canonical, How::Derived);
        }
    }

    /// 给事件副本补的 undo：ID 只由它点名的日志派生，规范 ID 按那条日志的规范 ID 重算。
    fn repair_undos(&mut self) {
        let ev = self.ev;
        for l in &ev.logs {
            let Some(target) = l.revokes else {
                continue;
            };
            if self.out.map.contains_key(&l.id) {
                continue;
            }
            self.out.hashes += 1;
            if rules::copy_repair_undo(&target) == l.id {
                let canonical = rules::copy_repair_undo(&self.out.canonical(&target));
                self.set(l.id, canonical, How::Derived);
            }
        }
    }

    // ---------------------------------------------------------------- 验不上的

    fn unverified(&mut self) {
        let mut rest: Vec<Id> = self
            .observed
            .iter()
            .filter(|id| !self.out.map.contains_key(id))
            .copied()
            .collect();
        rest.sort_unstable();
        for id in rest {
            let why = match self.why.get(&id) {
                Some(w) => *w,
                None if id.0[6] >> 4 == 7 => Why::NotDerived,
                None => Why::NoMatch,
            };
            self.out.map.insert(
                id,
                Entry {
                    canonical: id,
                    how: How::Unverified(why),
                    via: None,
                },
            );
        }
    }

    // ---------------------------------------------------------------- 写入者

    /// 旧并入改名的写入者：`merged-<H>`（2026-11 之前）与 `merged-<H>~<最初的写入者>`，
    /// `H = v5(NS, profile-merge/<目标 uid>/writer/<最初的写入者>)`。
    ///
    /// 哈希验上只说明「这个名字是从那个名字改来的」，不说明两个名字下的记录是同一套 seq：v1 的写入者名是
    /// `设备#代次`，序号却按 profile 记，同一个名字在两个 uid 下是两套互不相干的 seq。所以归过去还要正面证据
    /// （[WriterHow]）：两边有同 seq 的同一条记录，且没有同 seq 的不同记录。
    fn writers(&mut self) {
        type Dots = BTreeMap<u64, Option<(i64, i64)>>;
        #[derive(PartialEq)]
        enum Rel {
            Same,
            Differ,
            Unrelated,
        }
        fn relation(a: &Dots, b: &Dots) -> Rel {
            let (small, large) = if a.len() <= b.len() { (a, b) } else { (b, a) };
            let mut shared = false;
            for (seq, x) in small {
                if let Some(y) = large.get(seq) {
                    if x.is_none() || x != y {
                        return Rel::Differ;
                    }
                    shared = true;
                }
            }
            if shared { Rel::Same } else { Rel::Unrelated }
        }

        let ev = self.ev;
        // 在操作里出现过的名字与它名下的记录（同一个 seq 有两种戳 = 证据自相矛盾，记 None：和谁都对不上）。
        let mut dots: BTreeMap<&'a str, Dots> = BTreeMap::new();
        for w in &ev.writers {
            let d = dots.entry(w.name.as_str()).or_default();
            for x in &w.dots {
                let stamp = Some((x.physical, x.counter));
                d.entry(x.seq)
                    .and_modify(|s| {
                        if *s != stamp {
                            *s = None;
                        }
                    })
                    .or_insert(stamp);
            }
        }
        // 候选的名字：出现过的、提示的、名字里带着的（一层层剥）。
        let mut known: BTreeSet<String> = dots.keys().map(|s| (*s).to_owned()).collect();
        known.extend(ev.writer_hints.iter().cloned());
        let mut todo: Vec<String> = known.iter().cloned().collect();
        while let Some(w) = todo.pop() {
            if let Some((_, Some(e))) = parse_merged(&w) {
                if known.insert(e.to_owned()) {
                    todo.push(e.to_owned());
                }
            }
        }
        let wanted: HashSet<Id> = known
            .iter()
            .filter_map(|w| parse_merged(w).map(|(h, _)| h))
            .collect();
        if wanted.is_empty() {
            return;
        }
        // 正向算：候选的最初写入者 × 盐。算出来的 `merged-<H>` 自己也是下一跳的候选（链式并入里中间那个名字
        // 不在集合里）。合成的写入者旧并入不改名，不算候选。
        let mut by_hash: HashMap<Id, BTreeSet<String>> = HashMap::new();
        let mut virtual_parent: BTreeMap<String, String> = BTreeMap::new();
        let mut frontier: Vec<String> = known
            .iter()
            .filter(|w| !synthetic_writer(w))
            .cloned()
            .collect();
        for _ in 0..self.limits.writer_hops.max(1) {
            let mut next: Vec<String> = Vec::new();
            for o in &frontier {
                for s in &self.out.salts {
                    self.out.hashes += 1;
                    let h = rules::merged_writer_hash(s, o);
                    if wanted.contains(&h) {
                        by_hash.entry(h).or_default().insert(o.clone());
                    }
                    let v = format!("{MERGED_PREFIX}{}", h.text());
                    if !known.contains(&v) && !virtual_parent.contains_key(&v) {
                        virtual_parent.insert(v.clone(), o.clone());
                        next.push(v);
                    }
                }
            }
            if next.is_empty() {
                break;
            }
            frontier = next;
        }
        let parent_of = |w: &str| -> Option<String> {
            if let Some(p) = virtual_parent.get(w) {
                return Some(p.clone());
            }
            let (h, embedded) = parse_merged(w)?;
            let found = by_hash.get(&h)?;
            match embedded {
                // 名字里带着最初写入者的：哈希必须正是由它算出来的。
                Some(e) => found.contains(e).then(|| e.to_owned()),
                None => {
                    let mut it = found.iter().filter(|o| o.as_str() != w);
                    let first = it.next()?;
                    it.next().is_none().then(|| first.clone())
                }
            }
        };
        let root_of = |w: &str| -> Option<String> {
            let mut cur = parent_of(w)?;
            for _ in 0..64 {
                match parent_of(&cur) {
                    Some(p) => cur = p,
                    None => break,
                }
            }
            Some(cur)
        };
        // 最初的写入者 → 在操作里出现过、哈希验上归它的名字。
        let mut classes: BTreeMap<String, Vec<&'a str>> = BTreeMap::new();
        for w in dots.keys() {
            if let Some(root) = root_of(*w) {
                if root != *w {
                    classes.entry(root).or_default().push(*w);
                }
            }
        }
        let empty = Dots::new();
        for (root, members) in &classes {
            let root_dots = dots.get(root.as_str()).unwrap_or(&empty);
            // 同 seq 上是另一条记录的先排除（对最初的写入者、对这一类里别的名字都算）。
            let differs = |m: &str| {
                relation(&dots[m], root_dots) == Rel::Differ
                    || members
                        .iter()
                        .any(|x| *x != m && relation(&dots[m], &dots[x]) == Rel::Differ)
            };
            let clean: Vec<&str> = members.iter().copied().filter(|m| !differs(*m)).collect();
            // 剩下的里，与最初的写入者经「同 seq 同记录」连得上的。
            let mut joined: Vec<&str> = Vec::new();
            if !root_dots.is_empty() {
                let mut grew = true;
                while grew {
                    grew = false;
                    for m in &clean {
                        if joined.contains(m) || dots[m].is_empty() {
                            continue;
                        }
                        let near = relation(&dots[m], root_dots) == Rel::Same
                            || joined
                                .iter()
                                .any(|j| relation(&dots[m], &dots[j]) == Rel::Same);
                        if near {
                            joined.push(*m);
                            grew = true;
                        }
                    }
                }
            }
            for m in members {
                let how = if !clean.contains(m) {
                    WriterHow::DotsDiffer
                } else if joined.contains(m) {
                    WriterHow::Resolved
                } else {
                    WriterHow::Unproven
                };
                self.out.writers.insert(
                    (*m).to_owned(),
                    WriterEntry {
                        origin: root.clone(),
                        how,
                    },
                );
            }
        }
    }
}

const MERGED_PREFIX: &str = "merged-";

/// 普通类型的卡只有序号 0。
const NO_CLOZE: [i64; 1] = [0];

/// 旧并入不改名的合成写入者：标签迁移的 `sync2:…`，与给事件副本补 undo 用的固定名字。
fn synthetic_writer(w: &str) -> bool {
    w.starts_with("sync2:") || w == "repair-event-copy"
}

/// `merged-<UUID>` / `merged-<UUID>~<最初的写入者>` → (哈希, 名字里带的最初写入者)。
fn parse_merged(w: &str) -> Option<(Id, Option<&str>)> {
    let rest = w.strip_prefix(MERGED_PREFIX)?;
    if rest.len() < 36 || !rest.is_char_boundary(36) {
        return None;
    }
    let h = strict_id(&rest[..36])?;
    match &rest[36..] {
        "" => Some((h, None)),
        tail if tail.len() > 1 && tail.starts_with('~') => Some((h, Some(&tail[1..]))),
        _ => None,
    }
}

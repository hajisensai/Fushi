//! `ffc_text_*`：有声书 cue ↔ EPUB 正文匹配（`EpubSrtMatcher` 的算法主体）。
//!
//! 这里是**唯一实现**：起点检测（聚簇佐证 + 最长递增链收敛）、主循环（精确命中 /
//! 读音轨 / 滑窗 Dice 模糊兜底 / 尾巴回吃）、连续 miss 后的恢复扫描。Dart 侧
//! （packages/fushi_audio `epub_srt_matcher.dart`）只做数据准备：归一化全书串、
//! 读音轨与偏移映射、cue 归一化文本，以及把结果装回 `CueMatch`。算法的设计理由
//! （各条 BUG 号）写在 Dart 侧的类注释里，这里只注明与之对应的步骤。
//!
//! 字符串一律是 **UTF-16 码元**（与 Dart `String.codeUnitAt` 同一口径）：代理对按
//! 两个码元参与 bigram，偏移也是码元偏移。全部是整数运算加一次
//! `(matches * 2) as f64 / denom`，与旧 Dart 实现逐位一致（对拍夹具见
//! packages/fushi_audio/test/matching/fixtures）。
//!
//! 一次调用处理整本书 × 全部 cue × 多档窗口（各窗口互不依赖，按线程并行），不逐条
//! 跨 FFI。

use crate::{guard, status};
use memchr::memmem;

/// 调参常量，由 Dart 侧（`EpubSrtMatcher` 的 static const）按 [IntParam] 顺序传入；
/// 本模块不另存一份数值。
#[derive(Clone, Copy)]
struct Params {
    probe_count: usize,
    recover_min_support: i64,
    recover_scan_limit: usize,
    recover_max_fuzzy_probes: usize,
    recover_fuzzy_budget_total: i64,
    start_cluster_span: i64,
    probe_min_len: usize,
    short_cue_max_len: usize,
    short_cue_max_advance: i64,
    cue_tail_overlap: i64,
    max_exact_hits: usize,
    max_consecutive_misses: i64,
    threshold: f64,
    start_min_remaining_ratio: f64,
}

/// `int_params` 的下标（与 Dart 侧 `_kIntParam*` 一致）。
mod int_param {
    pub const PROBE_COUNT: usize = 0;
    pub const RECOVER_MIN_SUPPORT: usize = 1;
    pub const RECOVER_SCAN_LIMIT: usize = 2;
    pub const RECOVER_MAX_FUZZY_PROBES: usize = 3;
    pub const RECOVER_FUZZY_BUDGET_TOTAL: usize = 4;
    pub const START_CLUSTER_SPAN: usize = 5;
    pub const PROBE_MIN_LEN: usize = 6;
    pub const SHORT_CUE_MAX_LEN: usize = 7;
    pub const SHORT_CUE_MAX_ADVANCE: usize = 8;
    pub const CUE_TAIL_OVERLAP: usize = 9;
    pub const MAX_EXACT_HITS: usize = 10;
    pub const MAX_CONSECUTIVE_MISSES: usize = 11;
    pub const COUNT: usize = 12;
}

/// cue 标志位：原文以 `＊` / `*` 开头（旁白 / 标题），不参与聚簇探测。
const CUE_FLAG_SKIP_PROBE: u8 = 1;

/// 读音轨：任一章节带 ruby 时才有（偏移映射语义见 Dart `_ReadingTrack`）。
struct Reading<'a> {
    text: &'a [u16],
    to_base_start: &'a [i32],
    to_base_end: &'a [i32],
    atom_start: &'a [i32],
    atom_end: &'a [i32],
    from_base: &'a [i32],
}

impl Reading<'_> {
    /// 模糊命中的起点换回基底轨：落在某段读音中间时按剩余部分是否过半取整——过半
    /// 取该 ruby 基底起点，不足一半取其基底终点。不一律向外扩：bigram Dice 不看
    /// 顺序，窗口骑在两处相邻同读音 ruby 之间也能凑出高分，外扩会把只沾了两个
    /// 尾字的前一处 ruby 整个算进来、与上一条命中重叠（BUG-2928）。
    fn nearest_base_start(&self, p: usize) -> i64 {
        let r0 = self.atom_start[p] as i64;
        let pi = p as i64;
        if r0 >= pi {
            return self.to_base_start[p] as i64;
        }
        let r1 = self.atom_end[p] as i64;
        if (r1 - pi) * 2 >= r1 - r0 {
            self.to_base_start[p] as i64
        } else {
            self.to_base_end[p] as i64
        }
    }

    /// 终点版：覆盖过半取该 ruby 基底终点，否则取其基底起点。
    fn nearest_base_end(&self, e: usize) -> i64 {
        let r0 = self.atom_start[e] as i64;
        let ei = e as i64;
        if r0 >= ei {
            return self.to_base_end[e] as i64;
        }
        let r1 = self.atom_end[e] as i64;
        if (ei - r0) * 2 >= r1 - r0 {
            self.to_base_end[e] as i64
        } else {
            self.to_base_start[e] as i64
        }
    }
}

struct Book<'a> {
    base: &'a [u16],
    section_starts: &'a [i32],
    reading: Option<Reading<'a>>,
}

struct Cues<'a> {
    units: &'a [u16],
    offsets: &'a [i32],
    flags: &'a [u8],
}

impl Cues<'_> {
    fn len(&self) -> usize {
        self.flags.len()
    }

    fn text(&self, i: usize) -> &[u16] {
        &self.units[self.offsets[i] as usize..self.offsets[i + 1] as usize]
    }
}

fn as_bytes(s: &[u16]) -> &[u8] {
    // SAFETY: u16 切片按字节重解释，长度 ×2，对齐要求更低。
    unsafe { std::slice::from_raw_parts(s.as_ptr() as *const u8, s.len() * 2) }
}

/// `hay[from..]` 里 `needle` 首次出现、且整段落在 `[from, end)` 内的码元下标。
/// 等价于 Dart `hay.indexOf(needle, from)` 再判 `found + len <= end`：首次出现若
/// 越过 `end`，`[from, end)` 内不可能有更早的完整出现。
fn find_within(hay: &[u16], needle: &[u16], from: usize, end: usize) -> Option<usize> {
    let n = needle.len();
    if end > hay.len() || from > end || end - from < n {
        return None;
    }
    let nb = as_bytes(needle);
    let hb = as_bytes(&hay[from..end]);
    let mut off = 0usize;
    while off <= hb.len() {
        match memmem::find(&hb[off..], nb) {
            Some(i) => {
                let b = off + i;
                if b & 1 == 0 {
                    return Some(from + b / 2);
                }
                off = b + 1;
            }
            None => return None,
        }
    }
    None
}

// ---------- 滑窗 Dice ----------

#[derive(Clone, Copy)]
struct DiceResult {
    score: f64,
    pos: i64,
    len: usize,
}

/// needle 的 n-gram 计数表（开放寻址）：只有 needle 里出现的 gram 影响命中数，
/// 窗口里其余 gram 的计数与结果无关，所以只为 needle 的 gram 记窗口计数。
struct GramTable {
    keys: Vec<u32>,
    used: Vec<bool>,
    needle_count: Vec<i32>,
    window_count: Vec<i32>,
    mask: usize,
}

impl GramTable {
    fn new(needle: &[u16], n: usize) -> GramTable {
        let grams = if needle.len() >= n {
            needle.len() - n + 1
        } else {
            0
        };
        let mut cap = 8usize;
        while cap < grams * 2 + 2 {
            cap <<= 1;
        }
        let mut t = GramTable {
            keys: vec![0; cap],
            used: vec![false; cap],
            needle_count: vec![0; cap],
            window_count: vec![0; cap],
            mask: cap - 1,
        };
        for i in 0..grams {
            let slot = t.slot_for_insert(gram_key(needle, i, n));
            t.needle_count[slot] += 1;
        }
        t
    }

    #[inline]
    fn hash(key: u32) -> usize {
        (key.wrapping_mul(0x9E37_79B1) >> 7) as usize
    }

    fn slot_for_insert(&mut self, key: u32) -> usize {
        let mut i = Self::hash(key) & self.mask;
        loop {
            if !self.used[i] {
                self.used[i] = true;
                self.keys[i] = key;
                return i;
            }
            if self.keys[i] == key {
                return i;
            }
            i = (i + 1) & self.mask;
        }
    }

    #[inline]
    fn find(&self, key: u32) -> Option<usize> {
        let mut i = Self::hash(key) & self.mask;
        loop {
            if !self.used[i] {
                return None;
            }
            if self.keys[i] == key {
                return Some(i);
            }
            i = (i + 1) & self.mask;
        }
    }

    fn reset_window(&mut self) {
        for c in self.window_count.iter_mut() {
            *c = 0;
        }
    }
}

#[inline]
fn gram_key(s: &[u16], i: usize, n: usize) -> u32 {
    if n == 1 {
        s[i] as u32
    } else {
        ((s[i] as u32) << 16) | s[i + 1] as u32
    }
}

/// 滑窗 Dice：候选长度依次取 `len`、`len-1`、`len+1`，在 `hay[start..end)` 上滑，
/// 返回最高分（同分取先到者，满分即停）。与 Dart `_slidingDice` 同一算法。
fn sliding_dice(needle: &[u16], hay: &[u16], start: usize, end: usize) -> DiceResult {
    let mut best = DiceResult {
        score: 0.0,
        pos: -1,
        len: needle.len(),
    };
    let n_len = needle.len();
    let n = if n_len < 5 { 1 } else { 2 };
    let mut base_table: Option<GramTable> = None;
    let try_lens = [n_len as i64, n_len as i64 - 1, n_len as i64 + 1];
    for &try_len in try_lens.iter() {
        if try_len <= 0 {
            continue;
        }
        let try_len = try_len as usize;
        if end + 1 < try_len {
            continue;
        }
        let scan_end = end + 1 - try_len;
        if scan_end <= start {
            continue;
        }
        let tn = if n_len < 5 || try_len < 5 { 1 } else { 2 };
        if n_len < tn || try_len < tn {
            continue;
        }
        let needle_grams = n_len - tn + 1;
        let cand_grams = try_len - tn + 1;
        let denom = (needle_grams + cand_grams) as f64;

        let mut own_table;
        let table: &mut GramTable = if tn == n {
            if base_table.is_none() {
                base_table = Some(GramTable::new(needle, n));
            }
            let t = base_table.as_mut().unwrap();
            t.reset_window();
            t
        } else {
            own_table = GramTable::new(needle, tn);
            &mut own_table
        };

        let mut matches: i64 = 0;
        for i in start..=(start + try_len - tn) {
            if let Some(slot) = table.find(gram_key(hay, i, tn)) {
                table.window_count[slot] += 1;
            }
        }
        for slot in 0..table.keys.len() {
            if table.used[slot] {
                let c = table.window_count[slot];
                let nc = table.needle_count[slot];
                matches += if c < nc { c } else { nc } as i64;
            }
        }
        let mut sim = (matches * 2) as f64 / denom;
        if sim > best.score {
            best = DiceResult {
                score: sim,
                pos: start as i64,
                len: try_len,
            };
        }
        if best.score >= 1.0 {
            break;
        }
        for pos in (start + 1)..scan_end {
            if let Some(slot) = table.find(gram_key(hay, pos - 1, tn)) {
                let old = table.window_count[slot];
                if old <= table.needle_count[slot] {
                    matches -= 1;
                }
                table.window_count[slot] = old - 1;
            }
            if let Some(slot) = table.find(gram_key(hay, pos + try_len - tn, tn)) {
                let old = table.window_count[slot];
                if old < table.needle_count[slot] {
                    matches += 1;
                }
                table.window_count[slot] = old + 1;
            }
            sim = (matches * 2) as f64 / denom;
            if sim > best.score {
                best = DiceResult {
                    score: sim,
                    pos: pos as i64,
                    len: try_len,
                };
            }
            if best.score >= 1.0 {
                break;
            }
        }
        if best.score >= 1.0 {
            break;
        }
    }
    best
}

// ---------- 聚簇佐证（起点检测 / 恢复扫描） ----------

struct ClusterAnchor {
    pos: i64,
    support: i64,
    hitting_probes: i64,
    all_exact_unique: bool,
}

struct ClusterArgs {
    from_cue: usize,
    scan_limit: usize,
    max_fuzzy_probes: usize,
    min_remaining_ratio: f64,
    prefer_from: Option<i64>,
}

fn closer_ahead(from: i64, p: i64, best: i64) -> bool {
    let p_ahead = p >= from;
    let best_ahead = best >= from;
    if p_ahead != best_ahead {
        return p_ahead;
    }
    (p - from).abs() < (best - from).abs()
}

/// 簇 `[from, to]` 内按 (cue 序, 位置) 同时严格递增取最长链，返回链首；无命中 -1。
fn monotone_chain_start(kept: &[Vec<i64>], from: i64, to: i64) -> i64 {
    let mut items: Vec<(usize, i64)> = Vec::new();
    for (k, f) in kept.iter().enumerate() {
        for &q in f {
            if q >= from && q <= to {
                items.push((k, q));
            }
        }
    }
    items.sort();
    if items.is_empty() {
        return -1;
    }
    let mut length = vec![1usize; items.len()];
    let mut previous = vec![-1i64; items.len()];
    let mut best_end = 0usize;
    for j in 0..items.len() {
        for i in 0..j {
            if items[i].0 < items[j].0 && items[i].1 < items[j].1 && length[i] + 1 > length[j] {
                length[j] = length[i] + 1;
                previous[j] = i as i64;
            }
        }
        if length[j] > length[best_end] {
            best_end = j;
        }
    }
    let mut head = best_end;
    while previous[head] >= 0 {
        head = previous[head] as usize;
    }
    items[head].1
}

/// 起点检测与恢复扫描共用的「聚簇佐证」（BUG-2147 / BUG-2599）。
///
/// 从 `from_cue` 起最多扫 `scan_limit` 条 cue，凑 `probe_count` 条探测 cue（跳过
/// `＊` 旁白与短于 `probe_min_len` 的），每条在全书找候选：精确取前
/// `max_exact_hits` 处出现；精确失败且模糊配额（本次 `max_fuzzy_probes`、整次匹配
/// `fuzzy_budget`）未用完则做一次全书滑窗 Dice，≥ 阈值才算。候选 p 的支持数 = 有
/// 候选落在 `[p, p + start_cluster_span]` 内的探测 cue 条数；其后剩余正文装不下剩余
/// cue 总长 × `min_remaining_ratio` 的候选淘汰（片头念到书尾版权页的出版社名）。
///
/// 取支持数最大者；同分时 `prefer_from` 为空（起点）取最早，否则优先
/// `p >= prefer_from` 且离它最近——恢复时只有佐证**更多**的簇才会把游标往回搬。
/// 选出的簇再收敛到簇内按 (cue 序, 位置) 同时递增的最长链的链首：片头人名 / 泛用
/// 短语在正文里的偶然出现进不了链，不会把簇里其余真正文甩到游标之前。
fn cluster_anchor(
    book: &Book,
    cues: &Cues,
    p: &Params,
    a: &ClusterArgs,
    fuzzy_budget: &mut i64,
) -> Option<ClusterAnchor> {
    let big = book.base;
    let mut per_cue: Vec<Vec<i64>> = Vec::new();
    let mut per_cue_unique: Vec<bool> = Vec::new();
    let mut fuzzy_used = 0usize;
    let mut i = a.from_cue;
    while i < cues.len() && i - a.from_cue < a.scan_limit && per_cue.len() < p.probe_count {
        let idx = i;
        i += 1;
        if cues.flags[idx] & CUE_FLAG_SKIP_PROBE != 0 {
            continue;
        }
        let nc = cues.text(idx);
        if nc.len() < p.probe_min_len {
            continue;
        }
        let mut found: Vec<i64> = Vec::new();
        let finder = memmem::Finder::new(as_bytes(nc));
        let hb = as_bytes(big);
        let mut off = 0usize;
        while found.len() < p.max_exact_hits && off <= hb.len() {
            match finder.find(&hb[off..]) {
                Some(j) => {
                    let b = off + j;
                    if b & 1 == 0 {
                        found.push((b / 2) as i64);
                        off = b + 2; // 下一处从 at + 1 个码元起找
                    } else {
                        off = b + 1;
                    }
                }
                None => break,
            }
        }
        let exact_unique = found.len() == 1;
        if found.is_empty() && fuzzy_used < a.max_fuzzy_probes && *fuzzy_budget > 0 {
            fuzzy_used += 1;
            *fuzzy_budget -= 1;
            let r = sliding_dice(nc, big, 0, big.len());
            if r.pos >= 0 && r.score >= p.threshold {
                found.push(r.pos);
            }
        }
        if !found.is_empty() {
            per_cue.push(found);
            per_cue_unique.push(exact_unique);
        }
    }
    if per_cue.is_empty() {
        return None;
    }

    let mut min_remaining: i64 = 0;
    if a.min_remaining_ratio > 0.0 {
        let mut remaining_len: i64 = 0;
        for k in a.from_cue..cues.len() {
            remaining_len += cues.text(k).len() as i64;
        }
        min_remaining = (remaining_len as f64 * a.min_remaining_ratio).ceil() as i64;
    }
    let big_len = big.len() as i64;
    let mut kept: Vec<Vec<i64>> = Vec::new();
    let mut kept_unique: Vec<bool> = Vec::new();
    for (k, f) in per_cue.iter().enumerate() {
        let g: Vec<i64> = f
            .iter()
            .copied()
            .filter(|&q| big_len - q >= min_remaining)
            .collect();
        if g.is_empty() {
            continue;
        }
        kept.push(g);
        kept_unique.push(per_cue_unique[k]);
    }
    let mut candidates: Vec<i64> = kept.iter().flatten().copied().collect();
    candidates.sort();
    if candidates.is_empty() {
        return None;
    }

    let span = p.start_cluster_span;
    let mut best_pos = candidates[0];
    let mut best_support: i64 = -1;
    for &c in candidates.iter() {
        let mut support: i64 = 0;
        for f in kept.iter() {
            if f.iter().any(|&q| q >= c && q <= c + span) {
                support += 1;
            }
        }
        if support > best_support {
            best_support = support;
            best_pos = c;
        } else if support == best_support {
            if let Some(from) = a.prefer_from {
                if closer_ahead(from, c, best_pos) {
                    best_pos = c;
                }
            }
        }
    }
    let refined = monotone_chain_start(&kept, best_pos, best_pos + span);
    if refined >= 0 {
        best_pos = refined;
    }
    Some(ClusterAnchor {
        pos: best_pos,
        support: best_support,
        hitting_probes: kept.len() as i64,
        all_exact_unique: kept_unique.iter().all(|&u| u),
    })
}

// ---------- 主循环 ----------

#[derive(Clone, Copy)]
struct Hit {
    section: i32,
    start: i32,
    end: i32,
    score: f64,
}

const UNMATCHED: Hit = Hit {
    section: -1,
    start: -1,
    end: -1,
    score: 0.0,
};

struct WindowOutput {
    hits: Vec<Hit>,
    matched: i32,
    start_cursor: i32,
    final_cursor: i32,
    /// (cue 下标, 原游标, 新游标, 佐证数)
    recoveries: Vec<[i32; 4]>,
}

fn section_for_offset(starts: &[i32], offset: i64) -> usize {
    let mut lo: i64 = 0;
    let mut hi: i64 = starts.len() as i64 - 1;
    let mut ans: usize = 0;
    while lo <= hi {
        let mid = (lo + hi) >> 1;
        if starts[mid as usize] as i64 <= offset {
            ans = mid as usize;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    ans
}

fn match_window(book: &Book, cues: &Cues, p: &Params, search_window: i64) -> WindowOutput {
    let big = book.base;
    let total_len = big.len() as i64;
    let starts = book.section_starts;

    let mut start_budget = p.probe_count as i64;
    let start = cluster_anchor(
        book,
        cues,
        p,
        &ClusterArgs {
            from_cue: 0,
            scan_limit: p.probe_count,
            max_fuzzy_probes: p.probe_count,
            min_remaining_ratio: p.start_min_remaining_ratio,
            prefer_from: None,
        },
        &mut start_budget,
    )
    .map(|a| a.pos)
    .unwrap_or(0);

    let n = cues.len();
    let mut hits: Vec<Hit> = Vec::with_capacity(n);
    let mut recoveries: Vec<[i32; 4]> = Vec::new();
    let mut cursor: i64 = start;
    let mut matched: i32 = 0;
    let mut misses: i64 = 0;
    let mut recover_budget: i64 = p.recover_fuzzy_budget_total;
    let mut last_hit: i64 = -1;
    let mut last_hit_abs: i64 = -1;
    // 自上一条命中（或恢复重锚）以来 miss 掉的 cue 的归一化字数（短 cue 领先上限，
    // 见快速通道）。
    let mut missed_since_hit: i64 = 0;

    for ci in 0..n {
        let nc = cues.text(ci);
        let nc_len = nc.len() as i64;
        if nc.is_empty() {
            hits.push(UNMATCHED);
            continue;
        }

        // --- 恢复：连续 miss 过多时用聚簇佐证在全书重锚 ---
        // 找不到够佐证的位置就原地不动，再攒 max_consecutive_misses 次 miss 才试下
        // 一回。不做余量检查（剩余音频可能整段不在书里，书尾最后几句会被误杀）。
        if misses >= p.max_consecutive_misses {
            misses = 0;
            let anchor = cluster_anchor(
                book,
                cues,
                p,
                &ClusterArgs {
                    from_cue: ci,
                    scan_limit: p.recover_scan_limit,
                    max_fuzzy_probes: p.recover_max_fuzzy_probes,
                    min_remaining_ratio: 0.0,
                    prefer_from: Some(cursor),
                },
                &mut recover_budget,
            );
            // 往前搬：够 recover_min_support 条佐证，或（至少两条且）所有有候选的探测
            // cue 都落在这一簇、且每条在全书只精确出现一次（书尾只剩两三条正文 cue
            // 时凑不满三条）。单条撞中一律不搬；往回搬只认前者。
            if let Some(a) = anchor {
                if a.support >= p.recover_min_support
                    || (a.pos >= cursor
                        && a.hitting_probes >= 2
                        && a.support == a.hitting_probes
                        && a.all_exact_unique)
                {
                    recoveries.push([ci as i32, cursor as i32, a.pos as i32, a.support as i32]);
                    cursor = a.pos;
                    missed_since_hit = 0;
                    last_hit = -1;
                    last_hit_abs = -1;
                }
            }
        }

        let window_end = (cursor + search_window).clamp(0, total_len);
        // 读音轨只给 ≥ probe_min_len 的 cue 用：全假名的读音轨里三四个字的串随处
        // 可撞（TODO-906）。
        let reading = if nc.len() >= p.probe_min_len {
            book.reading.as_ref()
        } else {
            None
        };
        // BUG-2204：搜索起点允许回到游标前 cue_tail_overlap 字（不越过前一条命中的
        // 起点），被前一条多吃掉首字的本句仍能在真实位置命中。
        let search_from = if last_hit >= 0 {
            if cursor - p.cue_tail_overlap > last_hit_abs + 1 {
                cursor - p.cue_tail_overlap
            } else {
                last_hit_abs + 1
            }
        } else {
            cursor
        };
        // 读音轨命中换回基底轨后的下限（BUG-2928：不能叠回前一条命中的同一处 ruby）。
        let reading_floor = if last_hit >= 0 { last_hit_abs + 1 } else { 0 };

        // 本条在 [found] 处命中：前一条多吃的尾巴还给本条（BUG-2204）。
        let trim_previous = |hits: &mut Vec<Hit>, found: i64, cursor: i64, last_hit: i64| {
            if last_hit < 0 || found >= cursor {
                return;
            }
            let prev = hits[last_hit as usize];
            let prev_section_start = starts[prev.section as usize] as i64;
            let new_end = found - prev_section_start;
            if new_end <= prev.start as i64 {
                return;
            }
            hits[last_hit as usize].end = new_end as i32;
        };

        // --- 快速通道：精确命中（基底轨，再读音轨） ---
        if window_end - search_from >= nc_len {
            let mut found: i64 = -1;
            let mut match_end: i64 = -1;
            let mut hit = false;
            if let Some(f) = find_within(big, nc, search_from as usize, window_end as usize) {
                // 短 cue（不足 probe_min_len 字）的精确命中只认靠近游标的位置（「一」
                // 撞上「第一章」会把游标拽走）。一两个字的只能紧邻游标；三到五字的
                // （BUG-3519：「すげえ」撞上 170 字后的「すげえよなあ」）上限再加上
                // 自上一条命中以来 miss 掉的 cue 字数——前面有 cue 模糊没过线时游标
                // 停在原地，本句真实位置就在那几句之后。
                let max_advance = if nc.len() <= p.short_cue_max_len {
                    p.short_cue_max_advance
                } else {
                    p.short_cue_max_advance + missed_since_hit
                };
                let too_far = nc.len() < p.probe_min_len && (f as i64) > cursor + max_advance;
                found = f as i64;
                match_end = found + nc_len;
                hit = !too_far;
            }
            if !hit {
                if let Some(r) = reading {
                    let r_limit = r.from_base[window_end as usize] as usize;
                    let mut r_from = r.from_base[search_from as usize] as usize;
                    while let Some(rf) = find_within(r.text, nc, r_from, r_limit) {
                        let b0 = r.to_base_start[rf] as i64;
                        if b0 >= reading_floor {
                            found = b0;
                            match_end = r.to_base_end[rf + nc.len()] as i64;
                            hit = match_end > found;
                            break;
                        }
                        r_from = rf + 1;
                    }
                }
            }
            if hit {
                let sec = section_for_offset(starts, found);
                trim_previous(&mut hits, found, cursor, last_hit);
                last_hit = hits.len() as i64;
                last_hit_abs = found;
                let s0 = starts[sec] as i64;
                hits.push(Hit {
                    section: sec as i32,
                    start: (found - s0) as i32,
                    end: (match_end - s0) as i32,
                    score: 1.0,
                });
                cursor = match_end;
                matched += 1;
                misses = 0;
                missed_since_hit = 0;
                continue;
            }
        }

        // --- 模糊通道：滑窗 Dice（只给长 cue：短 cue 退化成 unigram，高频虚词
        // 随处凑够重叠，TODO-906）。基底轨够不到阈值时在读音轨同一窗口再扫，
        // 区间按覆盖过半就近取整到 ruby 边界（[Reading::nearest_base_start]）。 ---
        let mut best_sim = 0.0f64;
        let mut best_pos: i64 = -1;
        let mut best_len: i64 = nc_len;
        if nc.len() >= p.probe_min_len && window_end - cursor >= nc_len {
            let r = sliding_dice(nc, big, search_from as usize, window_end as usize);
            if r.score > best_sim {
                best_sim = r.score;
                best_pos = r.pos;
                best_len = r.len as i64;
            }
            if best_sim < p.threshold {
                if let Some(rd) = reading {
                    let r_start = rd.from_base[search_from as usize] as usize;
                    let r_end = rd.from_base[window_end as usize] as usize;
                    if r_end >= r_start && r_end - r_start >= nc.len() {
                        let rr = sliding_dice(nc, rd.text, r_start, r_end);
                        if rr.score > best_sim && rr.pos >= 0 {
                            let b0 = rd.nearest_base_start(rr.pos as usize);
                            let b1 = rd.nearest_base_end(rr.pos as usize + rr.len);
                            if b1 > b0 && b0 >= reading_floor {
                                best_sim = rr.score;
                                best_pos = b0;
                                best_len = b1 - b0;
                            }
                        }
                    }
                }
            }
        }

        if best_sim >= p.threshold && best_pos >= 0 {
            let match_end = best_pos + best_len;
            let sec = section_for_offset(starts, best_pos);
            trim_previous(&mut hits, best_pos, cursor, last_hit);
            last_hit = hits.len() as i64;
            last_hit_abs = best_pos;
            let s0 = starts[sec] as i64;
            hits.push(Hit {
                section: sec as i32,
                start: (best_pos - s0) as i32,
                end: (match_end - s0) as i32,
                score: best_sim,
            });
            cursor = match_end;
            matched += 1;
            misses = 0;
            missed_since_hit = 0;
        } else {
            hits.push(UNMATCHED);
            misses += 1;
            missed_since_hit += nc_len;
        }
    }

    WindowOutput {
        hits,
        matched,
        start_cursor: start as i32,
        final_cursor: cursor as i32,
        recoveries,
    }
}

/// 有声书 cue ↔ EPUB 匹配：对 `window_count` 档搜索窗口各跑一遍整本匹配。
///
/// 输入（全部由调用方准备，UTF-16 码元 / 码元偏移）：
/// - `base[base_len]`：归一化 + 小書き仮名折叠后的全书基底轨；
///   `section_starts[section_count]`：各节在其中的起点（单调不减，首项 0）。
/// - 读音轨（可无：`reading_text` 为空指针）：`reading_text[reading_len]`，
///   `reading_maps` 依次放 5 段 i32：`to_base_start[reading_len+1]`、
///   `to_base_end[reading_len+1]`、`atom_start[reading_len+1]`、
///   `atom_end[reading_len+1]`、`from_base[base_len+1]`。
/// - cue：`cue_units` 拼接的归一化文本，`cue_offsets[cue_count+1]` 分界，
///   `cue_flags[cue_count]`（bit0 = `＊` 旁白，不参与聚簇探测）。
/// - `windows[window_count]`；`int_params[int_param_count]`（下标见 [int_param]）、
///   `threshold`、`start_min_remaining_ratio`。
///
/// 输出（调用方分配）：`out_section` / `out_start` / `out_end`（节内偏移，未命中 -1）/
/// `out_score`（未命中 0）各 `window_count * cue_count`，按窗口分块；
/// `out_stats[window_count*3]` = 命中数、起点游标、终点游标；
/// `out_recover[window_count*cue_count*4]` = 每次恢复的 (cue, 原游标, 新游标, 佐证)，
/// 条数写进 `out_recover_count[window_count]`。
///
/// # Safety
/// 指针必须指向上述长度的有效内存（长度为 0 的数组可传空指针）。
#[no_mangle]
pub unsafe extern "C" fn ffc_text_cue_match(
    base: *const u16,
    base_len: usize,
    section_starts: *const i32,
    section_count: usize,
    reading_text: *const u16,
    reading_len: usize,
    reading_maps: *const i32,
    cue_units: *const u16,
    cue_units_len: usize,
    cue_offsets: *const i32,
    cue_flags: *const u8,
    cue_count: usize,
    windows: *const i32,
    window_count: usize,
    int_params: *const i32,
    int_param_count: usize,
    threshold: f64,
    start_min_remaining_ratio: f64,
    out_section: *mut i32,
    out_start: *mut i32,
    out_end: *mut i32,
    out_score: *mut f64,
    out_stats: *mut i32,
    out_recover: *mut i32,
    out_recover_count: *mut i32,
) -> i32 {
    guard(|| {
        if int_params.is_null() || int_param_count < int_param::COUNT || windows.is_null() {
            return status::NULL_ARGUMENT;
        }
        let out_len = window_count * cue_count;
        let need_out = window_count > 0;
        if need_out
            && (out_stats.is_null()
                || out_recover_count.is_null()
                || (out_len > 0
                    && (out_section.is_null()
                        || out_start.is_null()
                        || out_end.is_null()
                        || out_score.is_null()
                        || out_recover.is_null())))
        {
            return status::NULL_ARGUMENT;
        }
        if section_count == 0 || section_starts.is_null() || cue_offsets.is_null() {
            return status::NULL_ARGUMENT;
        }
        let ip = std::slice::from_raw_parts(int_params, int_param_count);
        if ip.iter().take(int_param::COUNT).any(|&v| v < 0) {
            return status::INVALID_ARGUMENT;
        }
        let params = Params {
            probe_count: ip[int_param::PROBE_COUNT] as usize,
            recover_min_support: ip[int_param::RECOVER_MIN_SUPPORT] as i64,
            recover_scan_limit: ip[int_param::RECOVER_SCAN_LIMIT] as usize,
            recover_max_fuzzy_probes: ip[int_param::RECOVER_MAX_FUZZY_PROBES] as usize,
            recover_fuzzy_budget_total: ip[int_param::RECOVER_FUZZY_BUDGET_TOTAL] as i64,
            start_cluster_span: ip[int_param::START_CLUSTER_SPAN] as i64,
            probe_min_len: ip[int_param::PROBE_MIN_LEN] as usize,
            short_cue_max_len: ip[int_param::SHORT_CUE_MAX_LEN] as usize,
            short_cue_max_advance: ip[int_param::SHORT_CUE_MAX_ADVANCE] as i64,
            cue_tail_overlap: ip[int_param::CUE_TAIL_OVERLAP] as i64,
            max_exact_hits: ip[int_param::MAX_EXACT_HITS] as usize,
            max_consecutive_misses: ip[int_param::MAX_CONSECUTIVE_MISSES] as i64,
            threshold,
            start_min_remaining_ratio,
        };

        let base = slice_or_empty(base, base_len);
        let section_starts = std::slice::from_raw_parts(section_starts, section_count);
        if section_starts[0] != 0
            || section_starts.windows(2).any(|w| w[0] > w[1])
            || section_starts[section_count - 1] as usize > base_len
        {
            return status::INVALID_ARGUMENT;
        }
        let cue_offsets = std::slice::from_raw_parts(cue_offsets, cue_count + 1);
        if cue_offsets[0] != 0
            || cue_offsets.windows(2).any(|w| w[0] > w[1])
            || cue_offsets[cue_count] as usize != cue_units_len
        {
            return status::INVALID_ARGUMENT;
        }
        let cues = Cues {
            units: slice_or_empty(cue_units, cue_units_len),
            offsets: cue_offsets,
            flags: slice_or_empty(cue_flags, cue_count),
        };
        let reading = if reading_text.is_null() {
            None
        } else {
            if reading_maps.is_null() {
                return status::NULL_ARGUMENT;
            }
            let r1 = reading_len + 1;
            let maps = std::slice::from_raw_parts(reading_maps, r1 * 4 + base_len + 1);
            let r = Reading {
                text: slice_or_empty(reading_text, reading_len),
                to_base_start: &maps[0..r1],
                to_base_end: &maps[r1..2 * r1],
                atom_start: &maps[2 * r1..3 * r1],
                atom_end: &maps[3 * r1..4 * r1],
                from_base: &maps[4 * r1..],
            };
            let in_reading = |v: &i32| *v >= 0 && *v as usize <= reading_len;
            let in_base = |v: &i32| *v >= 0 && *v as usize <= base_len;
            if !r.from_base.iter().all(in_reading)
                || !r.atom_start.iter().all(in_reading)
                || !r.atom_end.iter().all(in_reading)
                || !r.to_base_start.iter().all(in_base)
                || !r.to_base_end.iter().all(in_base)
            {
                return status::INVALID_ARGUMENT;
            }
            Some(r)
        };
        let book = Book {
            base,
            section_starts,
            reading,
        };
        let windows = std::slice::from_raw_parts(windows, window_count);

        let outputs: Vec<WindowOutput> = if windows.len() <= 1 {
            windows
                .iter()
                .map(|&w| match_window(&book, &cues, &params, w as i64))
                .collect()
        } else {
            std::thread::scope(|s| {
                let handles: Vec<_> = windows
                    .iter()
                    .map(|&w| {
                        let (book, cues, params) = (&book, &cues, &params);
                        s.spawn(move || match_window(book, cues, params, w as i64))
                    })
                    .collect();
                handles
                    .into_iter()
                    .map(|h| h.join().expect("match_window panicked"))
                    .collect()
            })
        };

        for (wi, out) in outputs.iter().enumerate() {
            let at = wi * cue_count;
            for (ci, h) in out.hits.iter().enumerate() {
                *out_section.add(at + ci) = h.section;
                *out_start.add(at + ci) = h.start;
                *out_end.add(at + ci) = h.end;
                *out_score.add(at + ci) = h.score;
            }
            *out_stats.add(wi * 3) = out.matched;
            *out_stats.add(wi * 3 + 1) = out.start_cursor;
            *out_stats.add(wi * 3 + 2) = out.final_cursor;
            let rec_at = wi * cue_count * 4;
            for (k, r) in out.recoveries.iter().enumerate() {
                for (j, v) in r.iter().enumerate() {
                    *out_recover.add(rec_at + k * 4 + j) = *v;
                }
            }
            *out_recover_count.add(wi) = out.recoveries.len() as i32;
        }
        status::OK
    })
}

unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 || ptr.is_null() {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

// ── 有声书 cue 重切：模糊命中的位置对齐（`CueSentenceResegmenter._alignPositions`）──

/// 编辑距离对齐：`map[i]` = `a[i]` 在 `b` 里对应的位置（删除的字符指向下一个对应位置），
/// `map[a.len()] = b.len()`，单调不减。`a.len() * b.len() > max_cells` 时退化为按比例线性
/// 映射 `round(i * m / n)`。与旧 Dart 实现同一套 DP 与回溯优先级（对角 → 删除 → 插入），
/// 全是整数运算外加一次 `(i * m) as f64 / n` 的四舍五入（Dart `round` = 远离零）。
///
/// `dp` 是复用的工作区（调用方跨多次调用保留，省掉逐对分配）。
pub fn align_positions(a: &[u16], b: &[u16], max_cells: i64, dp: &mut Vec<u32>, map: &mut [i32]) {
    let n = a.len();
    let m = b.len();
    debug_assert_eq!(map.len(), n + 1);
    map.fill(m as i32);
    if n == 0 {
        return;
    }
    if m == 0 {
        map.fill(0);
        return;
    }
    if (n as i64).saturating_mul(m as i64) > max_cells {
        for (i, slot) in map.iter_mut().enumerate() {
            *slot = ((i as i64 * m as i64) as f64 / n as f64).round() as i32;
        }
        return;
    }
    let w = m + 1;
    dp.clear();
    dp.resize((n + 1) * w, 0);
    for i in 1..=n {
        dp[i * w] = i as u32;
    }
    for j in 1..=m {
        dp[j] = j as u32;
    }
    for i in 1..=n {
        let ca = a[i - 1];
        let (prev, cur) = dp.split_at_mut(i * w);
        let prev = &prev[(i - 1) * w..];
        for j in 1..=m {
            let sub = prev[j - 1] + u32::from(ca != b[j - 1]);
            let del = prev[j] + 1;
            let ins = cur[j - 1] + 1;
            cur[j] = sub.min(del.min(ins));
        }
    }
    // 回溯：a[i-1] 与 b[j-1] 配对 → map[i-1] = j-1；a[i-1] 被删 → map[i-1] = j。
    let mut i = n;
    let mut j = m;
    while i > 0 {
        let cur = dp[i * w + j];
        if j > 0 && cur == dp[(i - 1) * w + j - 1] + u32::from(a[i - 1] != b[j - 1]) {
            map[i - 1] = (j - 1) as i32;
            i -= 1;
            j -= 1;
        } else if cur == dp[(i - 1) * w + j] + 1 {
            map[i - 1] = j as i32;
            i -= 1;
        } else {
            j -= 1;
        }
    }
}

/// 一次对齐整本书的全部模糊命中 cue（`CueSentenceResegmenter` 的重切前置步骤）。
///
/// 第 k 对：`a = a_units[a_offsets[k]..a_offsets[k+1]]`（cue 的归一化听写，UTF-16 码元），
/// `b = b_units[b_offsets[k]..b_offsets[k+1]]`（命中的正文切片）。两个偏移数组各
/// `count + 1` 项、首项 0、单调不减。输出按对顺序拼接，第 k 对占 `a_len_k + 1` 个 i32，
/// 起点 `a_offsets[k] + k`；`out_len` 必须恰为 `a_offsets[count] + count`，否则
/// [INVALID_ARGUMENT](status::INVALID_ARGUMENT)。各对互不依赖，逐位等同逐条调用
/// [align_positions]。
///
/// # Safety
/// 各指针按上面的长度可读 / 可写（长度为 0 的可为 NULL）。
#[no_mangle]
pub unsafe extern "C" fn ffc_text_align_positions(
    a_units: *const u16,
    a_units_len: usize,
    a_offsets: *const i32,
    b_units: *const u16,
    b_units_len: usize,
    b_offsets: *const i32,
    count: usize,
    max_cells: i64,
    out: *mut i32,
    out_len: usize,
) -> i32 {
    guard(|| {
        if a_offsets.is_null() || b_offsets.is_null() {
            return status::NULL_ARGUMENT;
        }
        let a_off = std::slice::from_raw_parts(a_offsets, count + 1);
        let b_off = std::slice::from_raw_parts(b_offsets, count + 1);
        let a_all: &[u16] = if a_units_len == 0 {
            &[]
        } else if a_units.is_null() {
            return status::NULL_ARGUMENT;
        } else {
            std::slice::from_raw_parts(a_units, a_units_len)
        };
        let b_all: &[u16] = if b_units_len == 0 {
            &[]
        } else if b_units.is_null() {
            return status::NULL_ARGUMENT;
        } else {
            std::slice::from_raw_parts(b_units, b_units_len)
        };
        let valid = |off: &[i32], len: usize| {
            off[0] == 0
                && off.windows(2).all(|w| w[0] <= w[1])
                && off[count] as i64 == len as i64
        };
        if !valid(a_off, a_all.len()) || !valid(b_off, b_all.len()) {
            return status::INVALID_ARGUMENT;
        }
        if out_len != a_all.len() + count {
            return status::INVALID_ARGUMENT;
        }
        if out_len > 0 && out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let out: &mut [i32] = if out_len == 0 {
            &mut []
        } else {
            std::slice::from_raw_parts_mut(out, out_len)
        };
        let mut dp: Vec<u32> = Vec::new();
        for k in 0..count {
            let a = &a_all[a_off[k] as usize..a_off[k + 1] as usize];
            let b = &b_all[b_off[k] as usize..b_off[k + 1] as usize];
            let at = a_off[k] as usize + k;
            align_positions(a, b, max_cells, &mut dp, &mut out[at..at + a.len() + 1]);
        }
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn find_within_respects_alignment_and_bounds() {
        // 0x0041 0x4100：字节序列里有跨码元的假命中，必须跳过。
        let hay: Vec<u16> = vec![0x0041, 0x4100, 0x0041, 0x0042];
        let needle: Vec<u16> = vec![0x0041, 0x0042];
        assert_eq!(find_within(&hay, &needle, 0, 4), Some(2));
        assert_eq!(find_within(&hay, &needle, 0, 3), None);
        assert_eq!(find_within(&hay, &needle, 3, 4), None);
    }

    #[test]
    fn dice_exact_window_scores_one() {
        let hay = u("あいうえおかきくけこさしすせそ");
        let needle = u("かきくけこさ");
        let r = sliding_dice(&needle, &hay, 0, hay.len());
        assert_eq!(r.score, 1.0);
        assert_eq!(r.pos, 5);
        assert_eq!(r.len, 6);
    }

    #[test]
    fn dice_matches_reference_formula() {
        // 与「逐位置重算 Dice」的朴素实现对拍。
        let hay = u("ここはどこあそこはそこかしこここはどこ");
        let needle = u("そこはどこかし");
        let fast = sliding_dice(&needle, &hay, 0, hay.len());
        let mut best = (0.0f64, -1i64, needle.len());
        for &tl in &[needle.len(), needle.len() - 1, needle.len() + 1] {
            let tn = if needle.len() < 5 || tl < 5 { 1 } else { 2 };
            for pos in 0..=(hay.len() - tl) {
                let cand = &hay[pos..pos + tl];
                let grams = |s: &[u16]| {
                    let mut m = std::collections::HashMap::new();
                    for i in 0..=(s.len() - tn) {
                        *m.entry(gram_key(s, i, tn)).or_insert(0i64) += 1;
                    }
                    m
                };
                let (a, b) = (grams(&needle), grams(cand));
                let inter: i64 = b
                    .iter()
                    .map(|(k, v)| (*v).min(*a.get(k).unwrap_or(&0)))
                    .sum();
                let sim = (inter * 2) as f64 / ((needle.len() - tn + 1) + (tl - tn + 1)) as f64;
                if sim > best.0 {
                    best = (sim, pos as i64, tl);
                }
            }
        }
        assert_eq!((fast.score, fast.pos, fast.len), best);
    }

    #[test]
    fn rejects_bad_offsets() {
        let base = u("あいうえお");
        let starts = [0i32];
        let offsets = [0i32, 9];
        let units = u("あい");
        let flags = [0u8];
        let windows = [200i32];
        let ip = [24i32, 3, 72, 8, 64, 3000, 6, 2, 16, 4, 8, 20];
        let mut sec = [0i32];
        let mut st = [0i32];
        let mut en = [0i32];
        let mut sc = [0f64];
        let mut stats = [0i32; 3];
        let mut rec = [0i32; 4];
        let mut rc = [0i32];
        let code = unsafe {
            ffc_text_cue_match(
                base.as_ptr(),
                base.len(),
                starts.as_ptr(),
                1,
                std::ptr::null(),
                0,
                std::ptr::null(),
                units.as_ptr(),
                units.len(),
                offsets.as_ptr(),
                flags.as_ptr(),
                1,
                windows.as_ptr(),
                1,
                ip.as_ptr(),
                ip.len(),
                0.8,
                0.5,
                sec.as_mut_ptr(),
                st.as_mut_ptr(),
                en.as_mut_ptr(),
                sc.as_mut_ptr(),
                stats.as_mut_ptr(),
                rec.as_mut_ptr(),
                rc.as_mut_ptr(),
            )
        };
        assert_eq!(code, status::INVALID_ARGUMENT);
    }

    #[test]
    fn align_positions_batch_matches_single_and_edges() {
        let u = |t: &str| t.encode_utf16().collect::<Vec<u16>>();
        let mut dp = Vec::new();
        let mut map = vec![0i32; 4];
        align_positions(&u("あいう"), &u(""), 400_000, &mut dp, &mut map);
        assert_eq!(map, vec![0, 0, 0, 0]);
        align_positions(&u("あいう"), &u("あいう"), 400_000, &mut dp, &mut map);
        assert_eq!(map, vec![0, 1, 2, 3]);
        let mut map = vec![0i32; 5];
        align_positions(&u("ああああ"), &u("あ"), 400_000, &mut dp, &mut map);
        assert_eq!(map, vec![0, 0, 0, 0, 1]);
        // 超预算：按比例 round(i * m / n)。
        let mut map = vec![0i32; 4];
        align_positions(&u("abc"), &u("abcdefgh"), 1, &mut dp, &mut map);
        assert_eq!(map, vec![0, 3, 5, 8]);

        let a: Vec<u16> = [u("あい"), u(""), u("ab")].concat();
        let b: Vec<u16> = [u("あう"), u("x"), u("")].concat();
        let a_off = [0i32, 2, 2, 4];
        let b_off = [0i32, 2, 3, 3];
        let mut out = vec![-1i32; 4 + 3];
        let st = unsafe {
            ffc_text_align_positions(
                a.as_ptr(), a.len(), a_off.as_ptr(),
                b.as_ptr(), b.len(), b_off.as_ptr(),
                3, 400_000, out.as_mut_ptr(), out.len(),
            )
        };
        assert_eq!(st, status::OK);
        assert_eq!(out, vec![0, 1, 2, 1, 0, 0, 0]);
        let st = unsafe {
            ffc_text_align_positions(
                a.as_ptr(), a.len(), a_off.as_ptr(),
                b.as_ptr(), b.len(), b_off.as_ptr(),
                3, 400_000, out.as_mut_ptr(), out.len() - 1,
            )
        };
        assert_eq!(st, status::INVALID_ARGUMENT);
    }
}

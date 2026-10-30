//! 原文 + 翻译按时间配对（设计 §5.2）：翻译**永远**挂成原文行的副行，不会变成独立行——
//! 独立行会被当成「当前行」参与逐字高亮，双语歌就成了两种语言轮流唱。
//!
//! 平台给的翻译常和原文不在同一条时间轴上：有的平台翻译轴跟着旧版行级 `lrc` 打时间，而逐字
//! 轴是另一套重新打的轴，两者整体差 1.5 s 上下、逐行再抖 ±0.4 s（实测样本见
//! `yrc_with_offset_translation_timeline`）。所以配对分三步：
//! 1. 估计整体偏移（让最多翻译行落进 [PAIR_WINDOW_MS] 的那个偏移）；
//! 2. 校正偏移后做单调序列对齐（DP），残差 ≤ [MAX_RESIDUAL_MS] 才算配上；
//! 3. 仍没配上的翻译挂到它校正后时刻所在的原文行（同语言追加成多行副文）。

use super::model::*;

/// 整体偏移估计时「同一行」的判定窗口。
pub const PAIR_WINDOW_MS: i64 = 300;

/// 整体偏移的搜索范围（翻译轴相对原文轴最多差这么多）。
pub const MAX_GLOBAL_OFFSET_MS: i64 = 5000;

/// 校正整体偏移后，一对行的起点最多还能差多少仍算同一行。
pub const MAX_RESIDUAL_MS: i64 = 1500;

/// 一行翻译不参与配对（走兜底挂靠）的代价；比任何合法配对都贵，DP 能配就配。
const SKIP_SECONDARY_COST: i64 = MAX_RESIDUAL_MS + 1;

pub fn merge_translation(primary: &Timeline, secondary: &Timeline, lang: &str) -> Timeline {
    if primary.timing_quality == TimingQuality::Unsynced {
        // 原文没有时间：无法按时间配对，原样返回原文。
        return primary.clone();
    }
    let mut out = primary.clone();
    // 原文主行（按起点排序的下标）；和声行不挂翻译。
    let mut mains: Vec<usize> = (0..out.lines.len())
        .filter(|&i| out.lines[i].role == Role::Main)
        .collect();
    mains.sort_by_key(|&i| (out.lines[i].start_ms, i));
    if mains.is_empty() {
        return out;
    }
    let mut secs: Vec<(i64, String)> = secondary
        .lines
        .iter()
        .filter(|l| l.role == Role::Main)
        .filter_map(|l| {
            let t = l.text();
            let t = t.trim();
            (!t.is_empty()).then(|| (l.start_ms, t.to_owned()))
        })
        .collect();
    if secs.is_empty() {
        return out;
    }

    if secondary.timing_quality == TimingQuality::Unsynced {
        // 翻译没有时间：按顺序一一对应，多出来的追加到最后一行。
        let last = *mains.last().unwrap();
        for (k, (_, txt)) in secs.iter().enumerate() {
            let target = mains.get(k).copied().unwrap_or(last);
            out.lines[target].add_translation(lang, txt);
        }
        return out;
    }

    secs.sort_by_key(|(s, _)| *s);
    let main_starts: Vec<i64> = mains.iter().map(|&i| out.lines[i].start_ms).collect();
    let sec_starts: Vec<i64> = secs.iter().map(|(s, _)| *s).collect();
    let offset = estimate_offset(&main_starts, &sec_starts);
    let pairing = align(&main_starts, &sec_starts, offset);
    for (k, (start, txt)) in secs.iter().enumerate() {
        let slot = pairing[k].unwrap_or_else(|| anchor_of(&main_starts, start - offset));
        out.lines[mains[slot]].add_translation(lang, txt);
    }
    out
}

/// 与 `t` 距离 ≤ [PAIR_WINDOW_MS] 的原文起点是否存在（`starts` 已升序）。
fn has_near(starts: &[i64], t: i64) -> bool {
    let p = starts.partition_point(|&s| s < t);
    (p < starts.len() && starts[p] - t <= PAIR_WINDOW_MS)
        || (p > 0 && t - starts[p - 1] <= PAIR_WINDOW_MS)
}

/// 整体偏移（翻译起点 − 原文起点）：候选取所有 |差| ≤ [MAX_GLOBAL_OFFSET_MS] 的行对之差与 0，
/// 选落进窗口的翻译行最多的；平手取 |偏移| 小的（对齐良好的数据保持 0）。
/// 再用窗口内配上的行差的中位数精修，减掉逐行抖动带来的偏置。
pub fn estimate_offset(main_starts: &[i64], sec_starts: &[i64]) -> i64 {
    let score = |d: i64| {
        sec_starts
            .iter()
            .filter(|&&s| has_near(main_starts, s - d))
            .count()
    };
    let mut best = (score(0), 0i64);
    for &s in sec_starts {
        let lo = main_starts.partition_point(|&m| m < s - MAX_GLOBAL_OFFSET_MS);
        for &m in &main_starts[lo..] {
            if m > s + MAX_GLOBAL_OFFSET_MS {
                break;
            }
            let d = s - m;
            let sc = score(d);
            if sc > best.0 || (sc == best.0 && d.abs() < best.1.abs()) {
                best = (sc, d);
            }
        }
    }
    let d = best.1;
    let mut deltas: Vec<i64> = sec_starts
        .iter()
        .filter_map(|&s| {
            let t = s - d;
            let p = main_starts.partition_point(|&m| m < t);
            [p.checked_sub(1), Some(p)]
                .into_iter()
                .flatten()
                .filter_map(|q| main_starts.get(q).copied())
                .min_by_key(|&m| (m - t).abs())
                .filter(|&m| (m - t).abs() <= PAIR_WINDOW_MS)
                .map(|m| s - m)
        })
        .collect();
    if deltas.is_empty() {
        return d;
    }
    deltas.sort_unstable();
    deltas[deltas.len() / 2]
}

/// 单调对齐：每行翻译至多配一行原文、顺序不交叉，总残差最小。返回每行翻译配上的原文槽位。
fn align(main_starts: &[i64], sec_starts: &[i64], offset: i64) -> Vec<Option<usize>> {
    let (n, m) = (sec_starts.len(), main_starts.len());
    const SKIP_MAIN: u8 = 1;
    const SKIP_SEC: u8 = 2;
    const MATCH: u8 = 3;
    let mut cost = vec![i64::MAX; (n + 1) * (m + 1)];
    let mut step = vec![0u8; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    cost[at(0, 0)] = 0;
    for i in 0..=n {
        for j in 0..=m {
            let c = cost[at(i, j)];
            if c == i64::MAX {
                continue;
            }
            if j < m && c < cost[at(i, j + 1)] {
                cost[at(i, j + 1)] = c;
                step[at(i, j + 1)] = SKIP_MAIN;
            }
            if i < n {
                let skip = c + SKIP_SECONDARY_COST;
                if skip < cost[at(i + 1, j)] {
                    cost[at(i + 1, j)] = skip;
                    step[at(i + 1, j)] = SKIP_SEC;
                }
                if j < m {
                    let r = (sec_starts[i] - offset - main_starts[j]).abs();
                    if r <= MAX_RESIDUAL_MS && c + r < cost[at(i + 1, j + 1)] {
                        cost[at(i + 1, j + 1)] = c + r;
                        step[at(i + 1, j + 1)] = MATCH;
                    }
                }
            }
        }
    }
    let mut out = vec![None; n];
    let (mut i, mut j) = (n, m);
    while i > 0 || j > 0 {
        match step[at(i, j)] {
            MATCH => {
                out[i - 1] = Some(j - 1);
                i -= 1;
                j -= 1;
            }
            SKIP_SEC => i -= 1,
            _ => j -= 1,
        }
    }
    out
}

/// 没配上的翻译挂靠的原文槽位：校正后时刻所在的那一行（起点 ≤ t + 窗口的最后一行），
/// 早于第一行时挂第一行。
fn anchor_of(main_starts: &[i64], t: i64) -> usize {
    main_starts
        .partition_point(|&m| m <= t + PAIR_WINDOW_MS)
        .saturating_sub(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn main_texts(t: &Timeline) -> Vec<String> {
        t.lines.iter().map(|l| l.text()).collect()
    }

    fn tr(l: &Line) -> Option<&str> {
        l.translations.first().map(|(_, t)| t.as_str())
    }

    #[test]
    fn aligned_pairs_and_strays_become_sub_lines() {
        let mut p = Timeline::new("lrc", TimingQuality::Line);
        p.lines.push(Line::whole("a", 1000, 2000));
        p.lines.push(Line::whole("b", 3000, 4000));
        let mut s = Timeline::new("lrc", TimingQuality::Line);
        s.lines.push(Line::whole("A", 1250, 2000));
        s.lines.push(Line::whole("X", 9000, 9500));
        s.lines.push(Line::whole("B", 3400, 4000));
        let m = merge_translation(&p, &s, "zh");
        assert_eq!(main_texts(&m), vec!["a", "b"], "翻译不得成为独立行");
        assert_eq!(tr(&m.lines[0]), Some("A"));
        assert_eq!(tr(&m.lines[1]), Some("B\nX"), "对不上的翻译挂到所在原文行");
    }

    #[test]
    fn global_offset_between_axes_is_compensated() {
        // 翻译整体晚 1.5 s、逐行抖 ±0.3 s：超出旧 300 ms 窗口，但应全部一一配上。
        let mut p = Timeline::new("yrc", TimingQuality::Syllable);
        let mut s = Timeline::new("lrc", TimingQuality::Line);
        let jitter = [0, 120, -250, 300, -100, 40, 210, -300];
        for (k, j) in jitter.iter().enumerate() {
            let start = 10_000 + k as i64 * 2600;
            p.lines
                .push(Line::whole(format!("o{k}"), start, start + 2000));
            s.lines
                .push(Line::whole(format!("t{k}"), start + 1500 + j, start + 3500));
        }
        let m = merge_translation(&p, &s, "zh");
        assert_eq!(m.lines.len(), jitter.len());
        for (k, l) in m.lines.iter().enumerate() {
            assert_eq!(l.text(), format!("o{k}"));
            assert_eq!(tr(l), Some(format!("t{k}").as_str()), "第 {k} 行");
        }
    }

    #[test]
    fn well_aligned_data_keeps_zero_offset() {
        let mains = [1000, 4000, 7000, 10_000];
        let secs = [1100, 3950, 7020, 10_050];
        assert!(estimate_offset(&mains, &secs).abs() <= 100);
    }

    #[test]
    fn unsynced_translation_pairs_by_order() {
        let mut p = Timeline::new("lrc", TimingQuality::Line);
        p.lines.push(Line::whole("a", 1000, 2000));
        p.lines.push(Line::whole("b", 3000, 4000));
        let mut s = Timeline::new("txt", TimingQuality::Unsynced);
        for t in ["A", "B", "C"] {
            s.lines.push(Line::whole(t, 0, 0));
        }
        let m = merge_translation(&p, &s, "zh");
        assert_eq!(main_texts(&m), vec!["a", "b"]);
        assert_eq!(tr(&m.lines[0]), Some("A"));
        assert_eq!(tr(&m.lines[1]), Some("B\nC"));
    }

    #[test]
    fn yrc_with_offset_translation_timeline() {
        // 按一首真实歌曲开头 6 行的时间轴改写（文字换成占位）：逐字轴与翻译轴整体差约 1.5 s。
        let yrc = "[11380,3030](11380,450,0)w1 (11830,270,0)w2 (12100,690,0)w3 (12790,270,0)w4 (13060,390,0)w5 (13450,960,0)w6 ne\n\
[14680,2310](14680,510,0)w7 (15190,210,0)w8 (15400,600,0)wx1 (16000,990,0)w9 ng\n\
[17350,3720](17350,600,0)w10 (17950,60,0)w11 (18010,360,0)w12 (18370,600,0)w13 (18970,420,0)w14 (19390,420,0)w15 (19810,1260,0)w16 \n\
[22000,3180](22000,450,0)w17 (22450,240,0)w18 (22690,420,0)w19 (23110,300,0)w20 (23410,300,0)w21 (23710,450,0)w22 (24160,1020,0)w23 ne\n\
[25360,2310](25360,480,0)w24 (25840,150,0)w25 (25990,630,0)w26 (26620,1050,0)w27 ng\n\
[53350,2430](53350,210,0)w28 (53560,330,0)w29 (53890,630,0)w30 (54520,330,0)w31 (54850,270,0)wx2 (55120,90,0)w32 (55210,570,0)w33 \n";
        let translation = "[by:x]\n\n[00:12.86]译文一\n[00:16.17]译文二\n\
[00:18.85]译文三\n[00:23.45]译文四\n[00:26.95]译文五\n[00:54.82]译文六\n";
        let p = crate::lyrics::parse(yrc.as_bytes(), "yrc", Some(225_200)).unwrap();
        let s = crate::lyrics::parse(translation.as_bytes(), "lrc", Some(225_200)).unwrap();
        let m = merge_translation(&p, &s, "zh-Hans");
        assert_eq!(m.lines.len(), p.lines.len(), "翻译不得成为独立行");
        let got: Vec<Option<&str>> = m.lines.iter().map(tr).collect();
        assert_eq!(
            got,
            vec![
                Some("译文一"),
                Some("译文二"),
                Some("译文三"),
                Some("译文四"),
                Some("译文五"),
                Some("译文六"),
            ]
        );
    }
}

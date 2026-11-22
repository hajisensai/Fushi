use super::*;

/// 测试用打包器：与 Dart `StatDeriveInput` 同一格式。
#[derive(Default)]
struct Pack {
    ints: Vec<i64>,
    ends: Vec<u32>,
    text: Vec<u16>,
}

impl Pack {
    fn i(&mut self, v: i64) -> &mut Self {
        self.ints.push(v);
        self
    }
    fn s(&mut self, v: &str) -> &mut Self {
        self.text.extend(v.encode_utf16());
        self.ends.push(self.text.len() as u32);
        self
    }
}

/// 解出的快照（字符串已还原）。
#[derive(Debug, PartialEq)]
struct Snap {
    daily: Vec<(String, String, String, String, String, [i64; 5])>,
    /// 每行：共享的 daily 下标，或 -1 + 自有行。
    hourly: Vec<(
        i64,
        Option<(String, String, String, String, String, [i64; 5])>,
    )>,
    sessions: Vec<(Vec<String>, [i64; 5], Option<i64>, Vec<String>)>,
    days: Vec<(String, i64, i64)>,
    book_days: Vec<(String, i64, i64)>,
    /// (来源码, 下标)。
    activity: Vec<(i64, i64)>,
}

fn decode(bytes: &[u8]) -> Snap {
    let rd = |o: usize| u64::from_le_bytes(bytes[o..o + 8].try_into().unwrap()) as usize;
    let (ni, ne, nt) = (rd(0), rd(8), rd(16));
    let ints: Vec<i64> = (0..ni)
        .map(|k| i64::from_le_bytes(bytes[24 + k * 8..32 + k * 8].try_into().unwrap()))
        .collect();
    let eo = 24 + ni * 8;
    let ends: Vec<usize> = (0..ne)
        .map(|k| u32::from_le_bytes(bytes[eo + k * 4..eo + k * 4 + 4].try_into().unwrap()) as usize)
        .collect();
    let to = eo + ne * 4;
    let text: Vec<u16> = (0..nt)
        .map(|k| u16::from_le_bytes(bytes[to + k * 2..to + k * 2 + 2].try_into().unwrap()))
        .collect();
    assert_eq!(bytes.len(), to + nt * 2);
    let strs: Vec<String> = (0..ne)
        .map(|k| {
            let start = if k == 0 { 0 } else { ends[k - 1] };
            String::from_utf16(&text[start..ends[k]]).unwrap()
        })
        .collect();
    let mut p = 0usize;
    let mut next = || {
        p += 1;
        ints[p - 1]
    };
    let fact = |next: &mut dyn FnMut() -> i64| {
        let s: Vec<String> = (0..5).map(|_| strs[next() as usize].clone()).collect();
        let n = [next(), next(), next(), next(), next()];
        (
            s[0].clone(),
            s[1].clone(),
            s[2].clone(),
            s[3].clone(),
            s[4].clone(),
            n,
        )
    };
    let nd = next();
    let daily = (0..nd).map(|_| fact(&mut next)).collect();
    let nh = next();
    let hourly = (0..nh)
        .map(|_| {
            let i = next();
            if i >= 0 {
                (i, None)
            } else {
                (-1, Some(fact(&mut next)))
            }
        })
        .collect();
    let ns = next();
    let sessions = (0..ns)
        .map(|_| {
            let s: Vec<String> = (0..5).map(|_| strs[next() as usize].clone()).collect();
            let n = [next(), next(), next(), next(), next()];
            let g = if next() >= 0 { Some(next()) } else { None };
            let m = next();
            let uids = (0..m).map(|_| strs[next() as usize].clone()).collect();
            (s, n, g, uids)
        })
        .collect();
    let totals = |next: &mut dyn FnMut() -> i64| {
        let n = next();
        (0..n)
            .map(|_| (strs[next() as usize].clone(), next(), next()))
            .collect::<Vec<_>>()
    };
    let days = totals(&mut next);
    let book_days = totals(&mut next);
    let na = next();
    let activity = (0..na).map(|_| (next(), next())).collect();
    assert_eq!(p, ints.len());
    Snap {
        daily,
        hourly,
        sessions,
        days,
        book_days,
        activity,
    }
}

fn run(p: &Pack) -> Result<Snap, BadInput> {
    derive(&p.ints, &p.ends, &p.text).map(|b| decode(&b))
}

/// 段一行（S uid, deviceId, kind, key, title, format, dateKey | I startAt, endAt, hour, ms, chars, pages）。
#[allow(clippy::too_many_arguments)]
fn seg(
    p: &mut Pack,
    uid: &str,
    dev: &str,
    kind: &str,
    key: &str,
    title: &str,
    date: &str,
    start: i64,
    end: i64,
    ms: i64,
    chars: i64,
) {
    p.s(uid).s(dev).s(kind).s(key).s(title).s("").s(date);
    p.i(start).i(end).i(9).i(ms).i(chars).i(0);
}

/// 只有段 + 游戏会话 + 名字的输入（其余表为空）。
fn sessions_input(
    gap: i64,
    segs: impl FnOnce(&mut Pack) -> i64,
    games: &[(&str, i64, i64, i64, i64)],
    names: &[(&str, &str)],
) -> Pack {
    let mut p = Pack::default();
    p.i(INPUT_VERSION).i(gap).i(0);
    for _ in 0..8 {
        p.i(0);
    }
    let at = p.ints.len();
    p.i(0);
    let n = segs(&mut p);
    p.ints[at] = n;
    p.i(0); // reviews
    p.i(games.len() as i64);
    for &(g, id, s, e, d) in games {
        p.s(g).i(id).i(s).i(e).i(d);
    }
    p.i(names.len() as i64);
    for &(k, v) in names {
        p.s(k).s(v);
    }
    p.i(0); // legacyActivity
    p
}

#[test]
fn calendar_day_key_matches_dart_format() {
    assert_eq!(calendar_day_key(0), "1970-01-01");
    assert_eq!(calendar_day_key(59), "1970-03-01");
    assert_eq!(calendar_day_key(20_454), "2026-01-01");
    assert_eq!(calendar_day_key(11_016), "2000-02-29");
    assert_eq!(calendar_day_key(-1), "1969-12-31");
}

#[test]
fn rejects_wrong_version_and_trailing_data() {
    let mut p = sessions_input(1, |_| 0, &[], &[]);
    p.ints[0] = INPUT_VERSION + 1;
    assert!(run(&p).is_err());
    let mut p = sessions_input(1, |_| 0, &[], &[]);
    p.i(7);
    assert!(run(&p).is_err());
    let mut p = sessions_input(1, |_| 0, &[], &[]);
    p.ints.pop();
    assert!(run(&p).is_err());
}

#[test]
fn empty_input_gives_empty_snapshot() {
    let s = run(&sessions_input(1, |_| 0, &[], &[])).unwrap();
    assert_eq!(
        s,
        Snap {
            daily: vec![],
            hourly: vec![],
            sessions: vec![],
            days: vec![],
            book_days: vec![],
            activity: vec![],
        }
    );
}

#[test]
fn facts_follow_legacy_order_and_identity_rules() {
    let mut p = Pack::default();
    p.i(INPUT_VERSION).i(1_800_000).i(0);
    // epubs：A 唯一、B 同名两本（不反查）。
    p.i(3);
    p.s("A").s("ka").s("epub");
    p.s("B").s("kb1").s("pdf");
    p.s("B").s("kb2").s("manga");
    // reading
    p.i(3);
    p.s("A").s("2026-01-02").i(10).i(20).i(1).i(100);
    p.s("B").s("2026-01-02").i(11).i(21).i(2).i(101);
    p.s("Gone").s("2026-01-03").i(12).i(22).i(3).i(102);
    // watch
    p.i(1);
    p.s("vu").s("V").s("2026-01-02").i(30).i(5).i(103);
    // readingHourly / videoHourly
    p.i(1);
    p.s("epub").s("2026-01-02").i(7).i(40);
    p.i(1);
    p.s("2026-01-02").i(8).i(50);
    // gameTitles / gameDaily
    p.i(1);
    p.s("g1").s("Old name");
    p.i(2);
    p.s("g1").s("2026-01-02").i(60);
    p.s("g2").s("2026-01-04").i(61);
    // gameActivity：零字数行不进。
    p.i(2);
    p.s("g1").s("Hook").s("2026-01-02").i(0).i(104);
    p.s("g1").s("Hook").s("2026-01-02").i(70).i(105);
    // segments：一条写零（不进）、一条有效。
    p.i(2);
    p.s("u0")
        .s("d")
        .s("book")
        .s("ka")
        .s("A")
        .s("epub")
        .s("2026-01-02")
        .i(1)
        .i(2)
        .i(3)
        .i(0)
        .i(0)
        .i(0);
    p.s("u1")
        .s("d")
        .s("book")
        .s("ka")
        .s("A")
        .s("epub")
        .s("2026-01-05")
        .i(1000)
        .i(2000)
        .i(4)
        .i(80)
        .i(90)
        .i(1);
    // reviews：时长 0 的格子不出。
    p.i(2);
    p.i(20_454).i(5).i(0).i(1);
    p.i(20_455).i(6).i(500).i(106);
    p.i(0).i(0).i(0); // gameSessions / gameNames / legacyActivity
    let s = run(&p).unwrap();
    let f = |k: &str, key: &str, t: &str, fm: &str, d: &str, n: [i64; 5]| {
        (k.into(), key.into(), t.into(), fm.into(), d.into(), n)
    };
    assert_eq!(
        s.daily,
        vec![
            f(
                "book",
                "ka",
                "A",
                "epub",
                "2026-01-02",
                [-1, 10, 20, 1, 100]
            ),
            f("book", "", "B", "", "2026-01-02", [-1, 11, 21, 2, 101]),
            f("book", "", "Gone", "", "2026-01-03", [-1, 12, 22, 3, 102]),
            f("video", "vu", "V", "", "2026-01-02", [-1, 30, 5, 0, 103]),
            f(
                "game",
                "g1",
                "Old name",
                "",
                "2026-01-02",
                [-1, 60_000, 0, 0, 0]
            ),
            f("game", "g2", "", "", "2026-01-04", [-1, 61_000, 0, 0, 0]),
            f("game", "g1", "Hook", "", "2026-01-02", [-1, 0, 70, 0, 105]),
            f(
                "book",
                "ka",
                "A",
                "epub",
                "2026-01-05",
                [4, 80, 90, 1, 2000]
            ),
            f("review", "srs", "", "", "2026-01-02", [6, 500, 0, 0, 106]),
        ]
    );
    assert_eq!(
        s.hourly,
        vec![
            (
                -1,
                Some(f("book", "", "", "epub", "2026-01-02", [7, 40, 0, 0, 0]))
            ),
            (
                -1,
                Some(f("video", "", "", "", "2026-01-02", [8, 50, 0, 0, 0]))
            ),
            (7, None),
            (8, None),
        ]
    );
    assert_eq!(
        s.days,
        vec![
            (
                "2026-01-02".into(),
                20 + 21 + 5 + 70,
                10 + 11 + 30 + 60_000 + 500
            ),
            ("2026-01-03".into(), 22, 12),
            ("2026-01-04".into(), 0, 61_000),
            ("2026-01-05".into(), 90, 80),
        ]
    );
    assert_eq!(
        s.book_days,
        vec![
            ("2026-01-02".into(), 41, 21),
            ("2026-01-03".into(), 22, 12),
            ("2026-01-05".into(), 90, 80)
        ]
    );
}

#[test]
fn sessions_merge_within_gap_and_split_beyond() {
    let p = sessions_input(
        100,
        |p| {
            seg(p, "a", "d", "book", "k", "T1", "x", 0, 50, 5, 1);
            seg(p, "b", "d", "book", "k", "", "x", 150, 200, 6, 2); // 150-50 = 100 ≤ gap：并
            seg(p, "c", "d", "book", "k", "T3", "x", 301, 400, 7, 3); // 301-200 > gap：新会话
            seg(p, "z", "d", "book", "k", "T0", "x", 500, 600, 0, 0); // 写零：不进
            4
        },
        &[],
        &[],
    );
    let s = run(&p).unwrap();
    assert_eq!(s.sessions.len(), 2);
    let (strs, nums, game, uids) = &s.sessions[0];
    assert_eq!(strs, &vec!["book", "k", "T3", "", "d"]);
    assert_eq!(nums, &[301, 400, 7, 3, 0]);
    assert_eq!((game, uids), (&None, &vec!["c".to_string()]));
    let (strs, nums, _, uids) = &s.sessions[1];
    assert_eq!(strs[2], "T1"); // 后一段 title 为空：保留上一段的
    assert_eq!(nums, &[0, 200, 11, 3, 0]);
    assert_eq!(uids, &vec!["a".to_string(), "b".to_string()]);
}

#[test]
fn game_skeleton_absorbs_overlapping_chars_and_drops_older_orphans() {
    let p = sessions_input(
        1_800_000,
        |p| {
            seg(p, "h1", "dev", "game", "g", "Hook", "x", 1000, 1100, 0, 40);
            seg(p, "h2", "dev", "game", "g", "Hook", "x", 1900, 2100, 0, 2); // 与骨架相交
            seg(p, "old", "dev", "game", "g", "Hook", "x", 10, 20, 0, 9); // 骨架窗口之前：丢
            seg(p, "out", "dev", "game", "g", "Hook", "x", 5000, 5100, 0, 3); // 窗口内、未被吸收
            4
        },
        &[("g", 7, 900, 2000, 60), ("g2", 8, 3000, 3500, 10)],
        &[("g", "Display")],
    );
    let s = run(&p).unwrap();
    let ends: Vec<i64> = s.sessions.iter().map(|x| x.1[1]).collect();
    assert_eq!(ends, vec![5100, 3500, 2000]);
    let skeleton = &s.sessions[2];
    assert_eq!(skeleton.0, vec!["game", "g", "Display", "", "dev"]);
    assert_eq!(skeleton.1, [900, 2000, 60_000, 42, 0]);
    assert_eq!(skeleton.2, Some(7));
    assert_eq!(skeleton.3, vec!["h1".to_string(), "h2".to_string()]);
    let empty_skeleton = &s.sessions[1];
    assert_eq!(empty_skeleton.0, vec!["game", "g2", "", "", ""]);
    assert!(empty_skeleton.3.is_empty());
    assert_eq!(s.sessions[0].3, vec!["out".to_string()]);
}

#[test]
fn group_order_compares_utf16_code_units() {
    // U+FF21（全角 A，单码元 0xFF21）> U+1F600（代理对，首码元 0xD83D）按 UTF-16；按码点则相反。
    let p = sessions_input(
        0,
        |p| {
            seg(p, "x", "\u{1F600}", "book", "k", "", "d", 0, 10, 1, 0);
            seg(p, "y", "\u{FF21}", "book", "k", "", "d", 0, 10, 1, 0);
            2
        },
        &[],
        &[],
    );
    let s = run(&p).unwrap();
    // 结束时刻并列：最终倒序排是 Dart 插入排序，保持归并后的顺序（代理对组在前）。
    let devices: Vec<&str> = s.sessions.iter().map(|x| x.0[4].as_str()).collect();
    assert_eq!(devices, vec!["\u{1F600}", "\u{FF21}"]);
}

#[test]
fn ffi_status_codes() {
    let mut out_ptr = std::ptr::null_mut();
    let mut out_len = 0usize;
    let p = sessions_input(1, |_| 0, &[], &[]);
    let one = [0u16];
    let one32 = [0u32];
    let code = unsafe {
        ffc_stats_derive(
            p.ints.as_ptr(),
            p.ints.len(),
            p.ends.as_ptr(),
            0,
            one.as_ptr(),
            0,
            &mut out_ptr,
            &mut out_len,
        )
    };
    assert_eq!(code, status::OK);
    assert!(
        decode(unsafe { std::slice::from_raw_parts(out_ptr, out_len) })
            .daily
            .is_empty()
    );
    crate::ffc_free_bytes(out_ptr, out_len);
    let code = unsafe {
        ffc_stats_derive(
            std::ptr::null(),
            0,
            one32.as_ptr(),
            0,
            one.as_ptr(),
            0,
            &mut out_ptr,
            &mut out_len,
        )
    };
    assert_eq!(code, status::NULL_ARGUMENT);
    let bad = [9i64];
    let code = unsafe {
        ffc_stats_derive(
            bad.as_ptr(),
            1,
            one32.as_ptr(),
            0,
            one.as_ptr(),
            0,
            &mut out_ptr,
            &mut out_len,
        )
    };
    assert_eq!(code, status::BAD_INPUT);
}

#[test]
fn activity_merges_sources_sorts_desc_and_truncates() {
    // 拼接顺序：legacy [L0=5, L1=30] → 非零段 [S0=10, S1=30]（写零段跳过）→ 骨架 [G0=30]。
    let build = |limit: i64| {
        let mut p = sessions_input(
            0,
            |p| {
                seg(p, "s0", "d", "book", "k", "", "x", 0, 10, 1, 0);
                seg(p, "zero", "d", "book", "k", "", "x", 0, 99, 0, 0);
                seg(p, "s1", "d", "video", "v", "", "x", 20, 30, 1, 0);
                3
            },
            &[("g", 1, 25, 30, 5)],
            &[],
        );
        p.ints[2] = limit;
        p.ints.pop();
        p.i(2).i(5).i(30);
        p
    };
    let s = run(&build(3)).unwrap();
    // 时刻并列（30）时 Dart 插入排序保持拼接顺序：L1、S1（下标 2）、G0。
    assert_eq!(s.activity, vec![(0, 1), (1, 2), (2, 0)]);
    let s = run(&build(10)).unwrap();
    assert_eq!(s.activity, vec![(0, 1), (1, 2), (2, 0), (1, 0), (0, 0)]);
    assert!(run(&build(0)).unwrap().activity.is_empty());
}

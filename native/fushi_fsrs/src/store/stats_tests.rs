//! store/stats.rs 的单测。聚合部分的用例与期望值照搬删除前的 Dart 单测（packages/fushi_engine/test/srs/
//! srs_stats_test.dart「SrsStatsData 聚合」「srsStatsBuckets」两组，2026-11-10），视图直接构造。

use super::*;

/// JST（+9）、4 点翻日。
const JST: Day = Day {
    utc_offset_min: 540,
    rollover_hour: 4,
};

/// JST 本地时间 → 毫秒。
fn jst(y: i64, m: i64, d: i64, h: i64) -> i64 {
    days_from_civil(y, m, d) * DAY_MS + h * HOUR_MS - 9 * HOUR_MS
}

fn day_start(day: i64) -> i64 {
    day * DAY_MS + JST.rollover_hour * HOUR_MS - JST.utc_offset_min * 60_000
}

#[derive(Default, Clone)]
struct C {
    id: &'static str,
    note: &'static str,
    deck: &'static str,
    state: Option<State>,
    days: i64,
    due_day: Option<i64>,
    due_at: Option<i64>,
    stab: Option<f64>,
    diff: Option<f64>,
    r: Option<f64>,
    suspended: bool,
    buried: bool,
    added_day: i64,
    desired: Option<f64>,
    by_recall: bool,
    src: Option<usize>,
}

fn queue_of(s: State) -> &'static str {
    match s {
        State::New => "new",
        State::Learning => "learning",
        State::Relearning => "relearning",
        State::Young | State::Mature => "review",
    }
}

/// 卡片 + 复习（card 下标, 日, 评分, 分类, 小时, 用时, 提前）+ 成熟变化 → (原料, 视图)。
fn fixture(
    now: i64,
    cards: &[C],
    reviews: &[(usize, i64, u8, u8, i64, i64, bool)],
    maturity: &[(usize, i64, i64)],
    sources: Vec<(String, String)>,
) -> (Snapshot, View) {
    let snap = Snapshot {
        profile: "p".into(),
        key: String::new(),
        gen: 0,
        cards: cards
            .iter()
            .map(|c| Card {
                id: c.id.into(),
                note: c.note.into(),
                deck: c.deck.into(),
                queue: queue_of(c.state.unwrap_or(State::New)).into(),
                days: c.days,
                suspended: c.suspended,
                buried_until: None,
                fushi: true,
                due_day: c.due_day,
                due_at: c.due_at,
                stab: c.stab,
                diff: c.diff,
                last: None,
                lapses: 0,
                reps: 0,
                added_at: 0,
                last_log: None,
                src: c.src,
            })
            .collect(),
        extra: Vec::new(),
        reviews: Vec::new(),
        sources,
    };
    let view = View {
        today: JST.index(now),
        now,
        derived: cards
            .iter()
            .map(|c| Derived {
                state: c.state.unwrap_or(State::New),
                buried: c.buried,
                by_recall: c.by_recall,
                r: c.r,
                added_day: c.added_day,
                desired: c.desired.unwrap_or(0.8),
            })
            .collect(),
        cards: (0..cards.len()).collect(),
        reviews: reviews
            .iter()
            .map(|&(card, day, rating, kind, hour, dur, early)| Review {
                card,
                at: day_start(day) + (hour - 4) * HOUR_MS,
                day,
                hour,
                rating,
                kind,
                dur,
                early,
            })
            .collect(),
        maturity: maturity.to_vec(),
    };
    (snap, view)
}

/// 视图的子集（Dart `SrsStatsData.subset`）。
fn subset(v: &View, keep: &[usize]) -> View {
    View {
        today: v.today,
        now: v.now,
        derived: v.derived.clone(),
        cards: v
            .cards
            .iter()
            .copied()
            .filter(|i| keep.contains(i))
            .collect(),
        reviews: v
            .reviews
            .iter()
            .copied()
            .filter(|r| keep.contains(&r.card))
            .collect(),
        maturity: v
            .maturity
            .iter()
            .copied()
            .filter(|m| keep.contains(&m.0))
            .collect(),
    }
}

fn agg(s: &Snapshot, v: &View, req: Value) -> Value {
    aggregate(s, v, JST, true, false, &req)
}

#[test]
fn buckets_daily_weekly_monthly() {
    let today = days_from_civil(2026, 10, 15);
    let (u1, b1) = buckets(today - 29, today);
    assert_eq!(u1, "day");
    assert_eq!(b1.len(), 30);
    let (u2, b2) = buckets(today - 364, today);
    assert_eq!(u2, "week");
    assert_eq!(*b2.last().unwrap(), (today - 6, today));
    assert_eq!(b2[0].0, today - 364);
    assert_eq!(b2.iter().map(|b| b.1 - b.0 + 1).sum::<i64>(), 365);
    let (u3, b3) = buckets(days_from_civil(2025, 1, 20), today);
    assert_eq!(u3, "month");
    assert_eq!(
        b3[0],
        (days_from_civil(2025, 1, 20), days_from_civil(2025, 1, 31))
    );
    assert_eq!(*b3.last().unwrap(), (days_from_civil(2026, 10, 1), today));
    assert_eq!(b3.len(), 22);
}

#[test]
fn civil_round_trips() {
    for d in [-800_000, -1, 0, 1, 59, 60, 11_016, 20_732, 2_932_896] {
        let (y, m, dd) = civil_from_days(d);
        assert_eq!(days_from_civil(y, m, dd), d, "{d} -> {y}-{m}-{dd}");
    }
    assert_eq!(civil_from_days(0), (1970, 1, 1));
    assert_eq!(civil_from_days(days_from_civil(2024, 2, 29)), (2024, 2, 29));
}

/// 「SrsStatsData 聚合」那组用例的数据。
fn sample() -> (Snapshot, View, i64) {
    let now = jst(2026, 10, 15, 21);
    let today = JST.index(now);
    let cards = [
        C {
            id: "a",
            note: "n1",
            deck: "d",
            state: Some(State::Learning),
            due_at: Some(now + 600_000),
            added_day: today,
            src: Some(0),
            ..C::default()
        },
        C {
            id: "b",
            note: "n2",
            deck: "d",
            state: Some(State::Mature),
            days: 30,
            due_day: Some(today + 30),
            stab: Some(40.0),
            diff: Some(5.5),
            r: Some(0.92),
            added_day: today - 60,
            desired: Some(0.9),
            src: Some(1),
            ..C::default()
        },
        C {
            id: "c",
            note: "n2",
            deck: "d",
            state: Some(State::Young),
            days: 2,
            due_day: Some(today - 3),
            stab: Some(2.0),
            diff: Some(9.0),
            r: Some(0.61),
            added_day: today - 60,
            desired: Some(0.8),
            src: Some(1),
            ..C::default()
        },
        C {
            id: "d",
            note: "n3",
            deck: "d",
            state: Some(State::Young),
            days: 5,
            due_day: Some(today + 1),
            stab: Some(5.0),
            diff: Some(1.0),
            suspended: true,
            added_day: today - 1,
            src: Some(2),
            ..C::default()
        },
        C {
            id: "e",
            note: "n4",
            deck: "d",
            state: Some(State::New),
            buried: true,
            added_day: today - 100,
            ..C::default()
        },
    ];
    let (a, b, c, d) = (0, 1, 2, 3);
    let reviews = [
        (a, today, 3, K_NEW, 9, 10_000, false),
        (a, today, 1, K_LEARN, 9, 10_000, false),
        (b, today, 4, K_MATURE, 21, 10_000, false),
        (c, today, 1, K_MATURE, 21, 10_000, false),
        (d, today, 3, K_YOUNG, 10, 10_000, true),
        (b, today - 1, 3, K_YOUNG, 10, 10_000, false),
        (b, today - 2, 2, K_YOUNG, 10, 10_000, false),
        (c, today - 4, 3, K_RELEARN, 10, 10_000, false),
        (c, today - 40, 3, 5, 10, 10_000, false),
    ];
    let sources = vec![
        ("book".to_owned(), "無職転生".to_owned()),
        ("book".to_owned(), "無職転生".to_owned()),
        ("video".to_owned(), "Frieren".to_owned()),
    ];
    let (s, v) = fixture(now, &cards, &reviews, &[], sources);
    (s, v, today)
}

#[test]
fn today_counts_duration_ratings_kinds_early_mature_rate() {
    let (s, v, _) = sample();
    let r = agg(&s, &v, json!({"range": "month"}));
    // [数量, 用时, 评分分布, 各类, 提前, 成熟答对, 成熟总数]
    assert_eq!(
        r["todayStats"],
        json!([5, 50_000, [2, 0, 2, 1], [1, 1, 1, 2, 0, 0], 1, 1, 2])
    );
}

#[test]
fn future_due_overdue_learning_suspended_load() {
    let (s, v, _) = sample();
    let r = agg(&s, &v, json!({"range": "month", "future": 31}));
    let f = &r["future"];
    assert_eq!(f["overdue"], 1); // c
    assert_eq!(f["perDay"][0], 1); // a（学习中）
    assert_eq!(f["perDay"][1], 0); // d 已暂停
    assert_eq!(f["perDay"][30], 1); // b
    assert_eq!(f["youngPerDay"][30], 0);
    assert_eq!(
        f["perDay"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_i64().unwrap())
            .sum::<i64>(),
        2
    );
    assert!((f["load"].as_f64().unwrap() - (1.0 + 1.0 / 30.0 + 1.0 / 2.0)).abs() < 1e-9);
}

#[test]
fn streak_from_today_and_longest() {
    let (s, v, _) = sample();
    assert_eq!(agg(&s, &v, json!({}))["streak"], json!([3, 3]));
}

#[test]
fn review_buckets_by_day_and_totals() {
    let (s, v, today) = sample();
    let r = agg(
        &s,
        &v,
        json!({"range": "month", "windows": {"range": [29, 0], "three": [89, 0]}}),
    );
    assert_eq!(r["reviews"]["unit"], "day");
    let b = r["reviews"]["buckets"].as_array().unwrap();
    assert_eq!(b.len(), 30);
    let last = &b[29];
    assert_eq!(last[0], today);
    assert_eq!(
        last[2]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_i64().unwrap())
            .sum::<i64>(),
        5
    );
    assert_eq!(last[2][K_MATURE as usize], 2);
    let total: i64 = b
        .iter()
        .map(|x| {
            x[2].as_array()
                .unwrap()
                .iter()
                .map(|y| y.as_i64().unwrap())
                .sum::<i64>()
        })
        .sum();
    assert_eq!(total, 8);
    // [.., 复习数, 用时, 学习天数, 天数]
    assert_eq!(r["windows"]["range"][6], 4);
    assert_eq!(r["windows"]["range"][4], 8);
    assert_eq!(r["windows"]["three"][4], 9);
}

#[test]
fn card_counts_suspended_and_buried_win() {
    let (s, v, _) = sample();
    // [新, 学习, 重学, 年轻, 成熟, 暂停, 搁置]
    assert_eq!(
        agg(&s, &v, json!({}))["cardCounts"],
        json!([0, 1, 0, 1, 1, 1, 1])
    );
}

#[test]
fn histograms_interval_difficulty_retrievability() {
    let (s, v, _) = sample();
    let r = agg(&s, &v, json!({}));
    let iv = &r["hist"]["interval"];
    assert_eq!(iv["total"], 3);
    assert!((iv["mean"].as_f64().unwrap() - (30.0 + 2.0 + 5.0) / 3.0).abs() < 1e-9);
    let d = &r["hist"]["difficulty"];
    assert_eq!(d["total"], 3);
    assert_eq!(d["bins"][0][2], 1); // D=1 → 0%
    let rt = &r["hist"]["retrievability"];
    assert_eq!(rt["total"], 2);
    assert!((rt["sum"].as_f64().unwrap() - 1.53).abs() < 1e-9);
}

#[test]
fn hourly_and_buttons() {
    let (s, v, _) = sample();
    let r = agg(&s, &v, json!({"range": "month"}));
    assert_eq!(r["hourly"][0][21], 2);
    assert_eq!(r["hourly"][1][21], 1);
    assert_eq!(r["hourly"][0][9], 2);
    assert_eq!(
        r["buttons"],
        json!([[1, 0, 2, 0], [0, 1, 2, 0], [1, 0, 0, 1]])
    );
    // 筛选复习不进按钮分布。
    let all = agg(&s, &v, json!({"range": "all"}));
    assert_eq!(all["buttons"][0], json!([1, 0, 2, 0]));
}

#[test]
fn true_and_desired_retention() {
    let (s, v, _) = sample();
    let r = agg(&s, &v, json!({"windows": {"m": [29, 0]}}));
    // [年轻答对, 年轻总数, 成熟答对, 成熟总数, ..]
    let w = &r["windows"]["m"];
    assert_eq!(
        (w[0].clone(), w[1].clone(), w[2].clone(), w[3].clone()),
        (json!(3), json!(3), json!(1), json!(2))
    );
    assert!((r["desiredRetention"].as_f64().unwrap() - (0.9 + 0.8 + 0.8) / 3.0).abs() < 1e-9);
}

#[test]
fn added_sources_subset_first_day() {
    let (s, v, today) = sample();
    let r = agg(&s, &v, json!({"range": "month"}));
    let added: Vec<i64> = r["added"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_i64().unwrap())
        .collect();
    assert_eq!(*added.last().unwrap(), 1);
    assert_eq!(added[28], 1);
    assert_eq!(added.iter().sum::<i64>(), 2);
    let src = r["sources"].as_array().unwrap();
    assert_eq!(src[0], json!(["book", "無職転生", 2]));
    assert!(src.iter().any(|x| x[0] == ""));
    let sub = subset(&v, &[1]);
    assert_eq!(sub.cards, vec![1]);
    assert_eq!(sub.reviews.len(), 3);
    assert_eq!(
        agg(&s, &v, json!({"range": "all"}))["firstDay"],
        today - 100
    );
}

#[test]
fn mature_growth_accumulates_at_bucket_ends() {
    let now = jst(2026, 10, 15, 21);
    let today = JST.index(now);
    let (s, v) = fixture(
        now,
        &[],
        &[],
        &[(0, today - 50, 1), (1, today - 5, 1), (0, today - 2, -1)],
        Vec::new(),
    );
    // 范围「一个月」逐日分桶：取 today-6、today-3、today 三个桶末。
    let r = agg(&s, &v, json!({"range": "month"}));
    let m: Vec<i64> = r["matureAt"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_i64().unwrap())
        .collect();
    assert_eq!((m[23], m[26], m[29]), (1, 2, 1));
}

#[test]
fn rwkv_now_due_near_and_daily_average() {
    let now = jst(2026, 10, 15, 21);
    let today = JST.index(now);
    let rwkv = |id: &'static str, r: f64, suspended: bool| C {
        id,
        note: id,
        deck: "d",
        state: Some(State::Mature),
        days: 30,
        suspended,
        r: Some(r),
        desired: Some(0.8),
        by_recall: true,
        ..C::default()
    };
    let cards = [
        rwkv("a", 0.8, false),  // = 目标：该复习
        rwkv("b", 0.84, false), // 接近
        rwkv("c", 0.9, false),
        rwkv("e", 0.1, true),
        C {
            id: "f",
            note: "nf",
            deck: "d2",
            state: Some(State::Young),
            due_day: Some(0),
            ..C::default()
        },
    ];
    let reviews = [
        (0, today, 3, K_MATURE, 9, 0, false),
        (1, today - 29, 3, K_MATURE, 9, 0, false),
        (1, today - 30, 3, K_MATURE, 9, 0, false), // 超出 30 天
        (4, today, 3, K_MATURE, 9, 0, false),      // FSRS 卡不算
    ];
    let (s, v) = fixture(now, &cards, &reviews, &[], Vec::new());
    let r = agg(&s, &v, json!({}));
    assert_eq!(r["rwkvNow"][0], 3);
    assert_eq!(r["rwkvNow"][1], 1);
    assert_eq!(r["rwkvNow"][2], 1);
    assert!((r["rwkvNow"][3].as_f64().unwrap() - 2.0 / 30.0).abs() < 1e-9);
    assert_eq!(r["hasDueDateCards"], true, "FSRS 卡 f 按到期日");
    let only = subset(&v, &[0, 1, 2]);
    assert_eq!(agg(&s, &only, json!({}))["hasDueDateCards"], false);
    let f = subset(&v, &[4]);
    assert_eq!(
        agg(&s, &f, json!({}))["rwkvNow"],
        Value::Null,
        "没有按 R 排队的卡"
    );
}

#[test]
fn dart_string_rules() {
    assert_eq!(dart_trim("\u{FEFF} 本 A \u{3000}"), "本 A");
    // U+FF5E（BMP 私用区之后）在 UTF-16 里大于代理对开头的 U+1F600，UTF-8 字节序相反。
    assert_eq!(
        dart_cmp("\u{FF5E}", "\u{1F600}"),
        std::cmp::Ordering::Greater
    );
    assert!("\u{FF5E}" < "\u{1F600}");
}

#[test]
fn histogram_shapes_follow_the_dart_rules() {
    // 95 分位以上截成「≥」：1..=100 天，p95 = 95 → 格宽 5，末格开口。
    let h = days_hist((1..=100).map(f64::from).collect());
    assert_eq!(h["openEnded"], true);
    assert_eq!(h["bins"].as_array().unwrap().len(), 20);
    assert_eq!(h["bins"][1], json!([5.0, 10.0, 5]));
    assert_eq!(h["median"], 50.5);
    let u = unit_hist(vec![0.0, 0.5, 1.0], 10);
    assert_eq!(u["bins"][9][2], 1, "1.0 落进末格");
    assert_eq!(days_hist(Vec::new())["total"], 0);
}

// ------------------------------------------------------------------ 原料与缓存

fn mem_store() -> Connection {
    let mut c = Connection::open_in_memory().unwrap();
    crate::store::schema::migrate(&mut c).unwrap();
    c
}

#[test]
fn snapshot_reads_visible_cards_sources_and_indexes_review_cards() {
    let c = mem_store();
    c.execute_batch(
        "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, source_kind, source_title) VALUES
           ('n1', 'p', 'T', 'g1', 100, 'book', ' A '), ('n2', 'p', 'T', 'g2', 200, '', ''),
           ('n3', 'p', 'T', 'g3', 300, 'book', ' A ');
         INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, hidden, note_created_at) VALUES
           ('c1', 'p', 'n1', 't', 'd', 0, 1), ('c2', 'p', 'n2', 't', 'd', 0, 2), ('c3', 'p', 'n3', 't', 'd', 0, 3),
           ('c4', 'p', 'nx', 't', 'd', 0, 4), ('h', 'p', 'n1', 't', 'd', 1, 5);
         INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at, rating) VALUES
           ('l1', 'p', 'c2', 10, 3), ('l2', 'p', 'gone', 20, 1), ('l3', 'p', 'c1', 30, NULL);",
    )
    .unwrap();
    let s = Snapshot::load(&c, "p").unwrap();
    assert_eq!(s.sizes(), (4, 3));
    // 两个出处（book " A " 与空种类），c4 没有笔记缓存行；n1 / n3 共用一个出处。
    assert_eq!(s.sources.len(), 2);
    assert_eq!(s.cards[0].src, s.cards[2].src);
    assert_eq!(s.cards[3].src, None);
    assert_eq!(s.cards[0].added_at, 100);
    assert_eq!(s.cards[3].added_at, 4);
    assert_eq!(s.extra, vec!["gone".to_owned()]);
    assert_eq!(s.reviews[1].card, 4);
    assert_eq!(s.reviews[2].rating, None);

    let ctx = Ctx::parse(&json!({"now": 0, "utcOff": 0, "rollover": 0})).unwrap();
    let all = report(&s, &ctx, &json!({"range": "all"}));
    // 归属到不可见卡的复习在全部范围里照算，牌组筛选后不算。
    assert_eq!(all["countsByDay"], json!([[0, 2]]));
    // 同数按种类（UTF-16 序）：没有出处的空种类在前。
    assert_eq!(all["sources"], json!([["", "", 2], ["book", "A", 2]]));
    let d = report(&s, &ctx, &json!({"range": "all", "decks": ["d"]}));
    assert_eq!(d["countsByDay"], json!([[0, 1]]));
    assert_eq!(all["retrievabilityAvailable"], false);
}

/// 原料按 profile + 指纹 + 写入代数缓存：写一笔之后（哪怕指纹没变）重读。
#[test]
fn snapshot_cache_rereads_after_a_write() {
    let core = super::super::kernel_reads_tests::open("stats_cache");
    let req = json!({"key": "k1", "now": 0, "utcOff": 0, "rollover": 0, "range": "all"});
    let a = core.stats_snapshot("p", "k1").unwrap();
    let b = core.stats_snapshot("p", "k1").unwrap();
    assert!(Arc::ptr_eq(&a, &b), "same key, no write: reused");
    let c = core.stats_snapshot("p", "k2").unwrap();
    assert!(!Arc::ptr_eq(&b, &c), "new key: reread");
    let g0 = core.study_hub.stats.generation();
    {
        let w = core.writer().unwrap();
        w.execute_batch(
            "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, hidden, note_created_at) \
             VALUES ('c1', srs_id('p'), 'n', 't', 'd', 0, 1)",
        )
        .unwrap();
    }
    assert!(core.study_hub.stats.generation() > g0);
    let d = core.stats_snapshot("p", "k2").unwrap();
    assert!(!Arc::ptr_eq(&c, &d), "written since: reread");
    assert_eq!(d.cards.len(), 1);
    assert_eq!(core.stats_report("p", &req).unwrap()["cardCounts"][0], 1);
    core.stats_release();
}

/// 首页（删除前 fushi/test/srs/srs_home_stats_test.dart 的口径）：今天的复习按卡片直接所在的牌组计、不可见卡的复习
/// 不归任何牌组（但算进今天总数）；「最近 N 天」窗口的次数与用时（平均用时 = 用时 / 次数）。
#[test]
fn home_today_by_deck_and_recent_window() {
    let now = jst(2026, 11, 4, 21);
    let today = JST.index(now);
    let young = |id: &'static str, deck: &'static str| C {
        id,
        note: id,
        deck,
        state: Some(State::Young),
        days: 3,
        ..C::default()
    };
    let cards = [young("a", "parent"), young("b", "child")];
    let reviews = [
        (0, today, 3, K_YOUNG, 12, 4_000, false),
        (0, today, 3, K_YOUNG, 12, 6_000, false),
        (1, today, 3, K_YOUNG, 12, 0, false),
        (1, today - 1, 3, K_YOUNG, 12, 8_000, false),
        // 下标 2 = 不可见卡（原料的 extra）。
        (2, today, 3, K_YOUNG, 12, 0, false),
        // 窗口外。
        (1, today - 7, 3, K_YOUNG, 12, 100_000, false),
    ];
    let (mut s, v) = fixture(now, &cards, &reviews, &[], Vec::new());
    s.extra.push("gone".into());
    let r = agg(&s, &v, json!({"windows": {"recent": [6, 0]}}));
    assert_eq!(r["todayByDeck"], json!({"child": 1, "parent": 2}));
    assert_eq!(r["todayStats"][0], 4);
    let w = &r["windows"]["recent"];
    assert_eq!(
        (w[4].clone(), w[5].clone(), w[7].clone()),
        (json!(5), json!(18_000), json!(7))
    );
    // 牌组子树：只数这些牌组里的卡。
    let sub = subset(&v, &[1]);
    let r = aggregate(&s, &sub, JST, true, true, &json!({}));
    assert_eq!(r["todayByDeck"], json!({"child": 1}));
}

/// 桌面小组件：学习 / 重学卡此刻之后的到期时刻、明天到期的复习卡数——只算没暂停、今天没搁置、不按回忆率排队的卡。
#[test]
fn widget_learning_due_ats_and_reviews_next_day() {
    let now = jst(2026, 11, 4, 21);
    let today = JST.index(now);
    let card = |id: &'static str, state: State| C {
        id,
        note: id,
        deck: "d",
        state: Some(state),
        days: if state == State::Mature { 30 } else { 3 },
        ..C::default()
    };
    let cards = [
        C {
            due_at: Some(now + 60_000),
            ..card("l1", State::Learning)
        },
        C {
            due_at: Some(now - 1),
            ..card("l2", State::Relearning)
        },
        C {
            due_at: Some(now + 5),
            suspended: true,
            ..card("l3", State::Learning)
        },
        C {
            due_at: Some(now + 7),
            buried: true,
            ..card("l4", State::Relearning)
        },
        C {
            due_at: Some(now + 9),
            ..card("l5", State::Relearning)
        },
        C {
            due_day: Some(today + 1),
            ..card("r1", State::Young)
        },
        C {
            due_day: Some(today + 1),
            by_recall: true,
            ..card("r2", State::Mature)
        },
        C {
            due_day: Some(today + 1),
            buried: true,
            ..card("r3", State::Young)
        },
        C {
            due_day: Some(today + 2),
            ..card("r4", State::Young)
        },
        C {
            due_day: Some(today + 1),
            ..card("r5", State::Mature)
        },
        C {
            due_day: Some(today + 1),
            ..card("n", State::New)
        },
    ];
    let (s, v) = fixture(now, &cards, &[], &[], Vec::new());
    let r = agg(&s, &v, json!({}));
    let mut at: Vec<i64> = r["learningDueAts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_i64().unwrap())
        .collect();
    at.sort();
    assert_eq!(at, vec![now + 9, now + 60_000]);
    assert_eq!(r["reviewsNextDay"], 2);
}

/// 带系列的出处（反馈 MCJLSBR5Wg；删除前 Dart `SrsStatsData.sourceShares` 的 `seriesTitle ?? title`）：制卡来源按
/// 系列名计（系列名去两侧空白），系列名全是空白 / 不是字符串 = 没有系列，照旧按集标题。从出处事件一路走到
/// `stats_report`：缓存刷新把系列名写进笔记缓存行（caches.rs `NoteInfo::of`），原料读的就是那一列。
#[test]
fn sources_count_series_notes_under_the_series_title() {
    use crate::store::caches::{CacheConfig, Dirty, refresh};
    use crate::store::sync2::in_savepoint;
    use crate::store::sync2::tests::{Device, P, deck_entity, edit};

    let d = Device::new("stats-series-sources");
    let deck = crate::store::sync2::config::default_deck_id(P);
    let note = |id: &str| json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": "NT"}}});
    let video = |media: &str, title: &str| json!({"kind": "video", "mediaKey": media, "startMs": 0, "title": title});
    let in_series = |media: &str, title: &str, series: Value| {
        let mut v = video(media, title);
        v["seriesTitle"] = series;
        v
    };
    let sources = [
        Some(in_series("e1", "RWBY - S01E01", json!("RWBY"))),
        Some(in_series("e2", "RWBY - S02E01", json!(" RWBY "))),
        Some(video("e3", "Solo")),
        Some(in_series("e4", " Solo ", json!("  "))),
        Some(in_series("e5", "Solo", json!(3))),
        None,
    ];
    let mut events = vec![
        deck_entity(&deck),
        json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
        edit(
            "notetype",
            "NT",
            "fieldDef/fa",
            json!({"name": "Expression", "ord": 0}),
        ),
        edit(
            "notetype",
            "NT",
            "tmplDef/t1",
            json!({"name": "C", "ord": 0, "front": "{{Expression}}"}),
        ),
    ];
    for (i, source) in sources.into_iter().enumerate() {
        let id = format!("0193a1b2-0000-7000-8000-00000000000{}", i + 1);
        events.push(note(&id));
        events.push(edit("note", &id, "f/fa", json!("猫")));
        if let Some(source) = source {
            events.push(edit("note", &id, "source", source));
        }
    }
    d.apply(1_700_000_000_000, events);
    let cfg = CacheConfig::parse(&json!({"defaultDeck": deck, "builtins": {}})).unwrap();
    {
        let w = d.core.writer().unwrap();
        let all = Dirty {
            all_notes: true,
            ..Dirty::default()
        };
        in_savepoint(&w, |c| refresh(c, P, &cfg, all)).unwrap();
    }
    let req = json!({"key": "k", "now": 1_700_000_000_000i64, "utcOff": 0, "rollover": 0, "range": "all"});
    let r = d.core.stats_report(P, &req).unwrap();
    assert_eq!(r["cardCounts"][0], 6, "one card per note: {r}");
    // 笔记数倒序，同数按种类、标题（UTF-16 序）：三条没有系列的记在集标题下，两集 RWBY 记在系列名下，一条没有出处。
    assert_eq!(
        r["sources"],
        json!([["video", "Solo", 3], ["video", "RWBY", 2], ["", "", 1]])
    );
    d.core.stats_release();
}

//! `discard.rs` 的执行计划测试：删除面的每条语句（对库里的每张表用 [delete_sql] 现拼）、[CACHE_GEN_BUMP_SQL]、
//! [META_DELETE_SQL] 与 [DISPOSABLE_SQL] 都走主键 / 索引，不整表扫。行为测试（换绑、删 profile、半截并入的收尾）经
//! C ABI 在 `cmd/profile_data_tests.rs`。

use rusqlite::Connection;

use super::*;
use crate::store::gen4::schema::open_in_memory;

/// [q] 的执行计划（`EXPLAIN QUERY PLAN` 的 detail 列；参数不绑，计划只看语句形状）。
fn plan(c: &Connection, q: &str) -> Vec<String> {
    let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
    let mut rows = stmt.raw_query();
    let mut out = Vec::new();
    while let Some(r) = rows.next().unwrap() {
        out.push(r.get::<_, String>(3).unwrap());
    }
    out
}

/// 计划里没有整表 / 整索引扫（`SCAN CONSTANT ROW` 是 `SELECT EXISTS(…)` 外层的常量行，不读表）。
fn assert_indexed(c: &Connection, q: &str) {
    let p = plan(c, q);
    assert!(!p.is_empty(), "{q}");
    assert!(
        p.iter()
            .all(|l| !l.starts_with("SCAN") || l == "SCAN CONSTANT ROW"),
        "{q}: {p:?}"
    );
}

#[test]
fn discard_statements_use_an_index() {
    let c = open_in_memory().unwrap();
    let t = Truth::new(&c);
    let all = tables(&t).unwrap();
    // 删除面覆盖真相层、本机状态、派生层、缓存层：几张代表表必须在清单里、寻址方式对。
    for (name, addr) in [
        ("devs", Addr::Col),
        ("trust", Addr::Col),
        ("derive_cfg", Addr::Col),
        ("loc_heads", Addr::Col),
        ("cache_gen", Addr::Col),
        ("ops", Addr::Key),
        ("op_alias", Addr::Key),
        ("op_voids", Addr::Key),
        ("op_pending", Addr::Key),
        ("op_forks", Addr::Key),
        ("op_wait", Addr::Key),
        ("log_marks", Addr::Dev),
    ] {
        assert!(
            all.iter().any(|(n, a)| n == name && *a == addr),
            "{name}: {all:?}"
        );
    }
    assert!(
        !all.iter()
            .any(|(n, _)| n == "collections" || n == "srs_meta"),
        "{all:?}"
    );
    for (name, addr) in &all {
        assert_indexed(&c, &delete_sql(name, *addr));
    }
    for q in [CACHE_GEN_BUMP_SQL, META_DELETE_SQL] {
        assert_indexed(&c, q);
    }
    for q in DISPOSABLE_SQL {
        assert_indexed(&c, q);
    }
}

/// 表名里的双引号转义（表名来自库里的 `sqlite_schema`，拼语句时照样防一手）。
#[test]
fn delete_sql_quotes_the_table_name() {
    assert_eq!(
        delete_sql("a\"b", Addr::Col),
        "DELETE FROM \"a\"\"b\" WHERE col = ?1"
    );
    assert_eq!(
        delete_sql("ops", Addr::Key),
        "DELETE FROM \"ops\" WHERE k BETWEEN ?1 AND ?2"
    );
    assert_eq!(
        delete_sql("log_marks", Addr::Dev),
        "DELETE FROM \"log_marks\" WHERE dev = ?1"
    );
}

/// [META_DELETE_SQL] 只删 `<前缀><col>` 与 `<前缀><col>/…`：别的集合号（含 `1` 与 `10` 这种前缀相同的）一条不碰。
#[test]
fn meta_delete_takes_only_this_collections_keys() {
    let c = open_in_memory().unwrap();
    for k in [
        "self_info/1",
        "self_info/10",
        "gen4_out/1/a",
        "gen4_out/1/b",
        "gen4_out/10/a",
        "gen4_out/1",
        "gen4_out/2/a",
        "gen4_out/1-",
    ] {
        c.execute("INSERT INTO srs_meta (key, value) VALUES (?1, 'v')", [k])
            .unwrap();
    }
    let mut n = 0;
    for prefix in ["self_info/", "gen4_out/"] {
        n += c
            .execute(
                META_DELETE_SQL,
                [format!("{prefix}1"), format!("{prefix}1/")],
            )
            .unwrap();
    }
    assert_eq!(n, 4);
    let left: Vec<String> = c
        .prepare("SELECT key FROM srs_meta WHERE key LIKE 'self_info/%' OR key LIKE 'gen4_out/%' ORDER BY key")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(
        left,
        vec![
            "gen4_out/1-",
            "gen4_out/10/a",
            "gen4_out/2/a",
            "self_info/10"
        ]
    );
}

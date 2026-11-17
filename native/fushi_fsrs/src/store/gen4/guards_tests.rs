//! 换代整批的源码守卫（规划 `docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md` §6「源码守卫」六条里归内核的三条；
//! 另三条在 Dart：`fushi/test/build/backup_srs_gen4_guard_test.dart`、`fushi/test/build/srs_gen4_source_guard_test.dart`）。
//!
//! - **活代码里没有旧表名**（设计 §2.4）：新代的命令层与派生层不碰协议 3 的表。按目录枚举 `store/gen4/` 下全部源码
//!   （新加的文件自动进来），去掉注释与测试代码后找协议 3 的表名。表名本身也不手抄：从协议 3 存储层源码的
//!   `CREATE TABLE` 里取（`srs_*` / `sync2_*`，减去新代自己也有的 `srs_meta`）。只有冻结侧（读入器 / 迁移 / 对拍）
//!   可以写旧表名，逐个登记理由；登记了却已不碰旧表的条目同样报错（不留死条目给后来者绕行）。
//! - **SCHEMA 冻结**：空库上 [schema::install] 建出的全部对象（表、索引、触发器、视图的 SQL）与文件头魔数的指纹，
//!   必须等于 [FROZEN] 里最后一条为当前 [schema::SCHEMA] 记下的那份。改了表 / 索引 / 触发器却没升 SCHEMA（旧库
//!   打开时认成同一版、不补建）、或升了 SCHEMA 没记新指纹，都在这里红。
//! - **每条命令都登记**：规划写的是 `store/ops.rs`；`ops.rs` 只在没合入的 `pr/srs-ffi-op-meta` 分支上，集成分支上
//!   命令的登记表是 [dispatch::wiring]。这里按源码核对：分发器 `run` 里的每个命令臂都登记成 `Wired`，登记成 `Wired`
//!   的每条都有臂（漏臂在运行时才报 `NO_ARM`）。协议 3 的每条命令都有去向由 `ffi.rs`
//!   `every_protocol_3_command_has_a_gen4_wiring` 管；Dart 发出的命令都在登记表里由 Dart 侧守卫管。

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use super::dispatch::{Wiring, wiring};
use super::schema;

/// 冻结的新代 schema：`(SCHEMA, 指纹)`，按号递增追加、旧条目不删（升号的历史）。指纹的算法见 [fingerprint]。
///
/// 改表的 PR：升 [schema::SCHEMA]（`schema.rs` 文件头记一句为什么）、在这里追加一条新号与新指纹（失败信息里给出），
/// 并写好旧库的升级路径。
const FROZEN: &[(i64, &str)] = &[(
    40_021,
    "6299b87ca156012522a800823053f7db38c5807661c3a35ef5a26c9e605abd32",
)];

fn src_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

/// 目录下的全部 `.rs`（递归，按路径排序）。
fn rust_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap_or_else(|e| panic!("{}: {e}", d.display())) {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "rs") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// 相对 `src/store/gen4/` 的路径（`/` 分隔）。
fn rel(base: &Path, p: &Path) -> String {
    p.strip_prefix(base)
        .unwrap()
        .to_string_lossy()
        .replace('\\', "/")
}

/// 整个文件都是测试：`*_tests.rs` / `tests*.rs`，或在父模块里以 `#[cfg(test)]` 声明的模块（如 `parity.rs`）。
fn is_test_file(p: &Path, test_mods: &BTreeSet<PathBuf>) -> bool {
    let name = p.file_name().unwrap().to_string_lossy();
    name.ends_with("_tests.rs") || name.starts_with("tests") || test_mods.contains(p)
}

/// [dir] 下各 `mod.rs` 里紧跟在 `#[cfg(test)]` 后面声明的 `mod x;` 对应的文件。
fn cfg_test_modules(dir: &Path) -> BTreeSet<PathBuf> {
    let mut out = BTreeSet::new();
    for p in rust_files(dir) {
        if p.file_name().is_none_or(|n| n != "mod.rs") {
            continue;
        }
        let src = std::fs::read_to_string(&p).unwrap().replace("\r\n", "\n");
        let lines: Vec<&str> = src.lines().map(str::trim).collect();
        for w in lines.windows(2) {
            if w[0] != "#[cfg(test)]" {
                continue;
            }
            let decl = w[1]
                .trim_start_matches("pub(crate) ")
                .trim_start_matches("pub ");
            if let Some(name) = decl.strip_prefix("mod ").and_then(|m| m.strip_suffix(';')) {
                out.insert(p.parent().unwrap().join(format!("{name}.rs")));
            }
        }
    }
    out
}

/// 去掉注释（`//…`、可嵌套的 `/* */`），字符串与字符字面量原样保留；行数不变（注释换成空格，换行留着）。
fn mask_comments(src: &str) -> String {
    let b: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let next = b.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && next == Some('*') {
            let mut depth = 0;
            while i < b.len() {
                if b[i] == '/' && b.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if b[i] == '*' && b.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    if b[i] == '\n' {
                        out.push('\n');
                    }
                    i += 1;
                }
            }
            continue;
        }
        // 原始字符串 r"…" / r#"…"#（前面可带 b）。
        if c == 'r'
            && (next == Some('"') || next == Some('#'))
            && (i == 0 || !(b[i - 1].is_alphanumeric() || b[i - 1] == '_'))
        {
            let mut j = i + 1;
            let mut hashes = 0;
            while b.get(j) == Some(&'#') {
                hashes += 1;
                j += 1;
            }
            if b.get(j) == Some(&'"') {
                let close: String = std::iter::once('"')
                    .chain(std::iter::repeat_n('#', hashes))
                    .collect();
                let rest: String = b[j + 1..].iter().collect();
                let end = rest.find(&close).map_or(b.len(), |k| {
                    j + 1 + rest[..k].chars().count() + close.chars().count()
                });
                out.extend(&b[i..end]);
                i = end;
                continue;
            }
        }
        if c == '"' {
            out.push(c);
            i += 1;
            while i < b.len() {
                out.push(b[i]);
                if b[i] == '\\' {
                    if let Some(&e) = b.get(i + 1) {
                        out.push(e);
                    }
                    i += 2;
                    continue;
                }
                i += 1;
                if b[i - 1] == '"' {
                    break;
                }
            }
            continue;
        }
        // 字符字面量（含 `'"'`），不是生命周期。
        if c == '\'' {
            if next == Some('\\') {
                let end = (i + 2..b.len())
                    .find(|&k| b[k] == '\'')
                    .map_or(b.len(), |k| k + 1);
                out.extend(&b[i..end]);
                i = end;
                continue;
            }
            if b.get(i + 2) == Some(&'\'') {
                out.extend(&b[i..i + 3]);
                i += 3;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 文件里的非测试代码：去掉注释，再截掉第一个 `#[cfg(test)]` 之后的部分（各文件的测试模块都在末尾）。
fn live_code(src: &str) -> String {
    let code = mask_comments(&src.replace("\r\n", "\n"));
    match code.find("#[cfg(test)]") {
        Some(at) => code[..at].to_owned(),
        None => code,
    }
}

fn is_ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// [text] 里以整词出现的 [names]，带行号。
fn word_hits(text: &str, names: &BTreeSet<String>) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let mut at = 0;
        while at < line.len() {
            let Some(k) = line[at..].find(|c: char| is_ident(c)) else {
                break;
            };
            let start = at + k;
            let end = line[start..]
                .find(|c: char| !is_ident(c))
                .map_or(line.len(), |e| start + e);
            let word = &line[start..end];
            if names.contains(word) {
                out.push((n + 1, word.to_owned()));
            }
            at = end;
        }
    }
    out
}

/// `CREATE TABLE [IF NOT EXISTS] <名字>` 里的名字。
fn created_tables(src: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut rest = src;
    while let Some(k) = rest.find("CREATE TABLE ") {
        rest = &rest[k + "CREATE TABLE ".len()..];
        let r = rest.strip_prefix("IF NOT EXISTS ").unwrap_or(rest);
        let name: String = r.chars().take_while(|&c| is_ident(c)).collect();
        if !name.is_empty() {
            out.insert(name);
        }
    }
    out
}

/// 协议 3 的表名：`store/` 下除新代以外的存储层源码里建的 `srs_*` / `sync2_*` 表，减去新代自己也建的。
fn protocol_3_tables() -> BTreeSet<String> {
    let store = src_root().join("store");
    let gen4 = store.join("gen4");
    let mut old = BTreeSet::new();
    for p in rust_files(&store) {
        if p.starts_with(&gen4) {
            continue;
        }
        let src = std::fs::read_to_string(&p).unwrap();
        old.extend(
            created_tables(&src)
                .into_iter()
                .filter(|t| t.starts_with("srs_") || t.starts_with("sync2_")),
        );
    }
    let conn = schema::open_in_memory().unwrap();
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_schema WHERE type = 'table'")
        .unwrap();
    let new: BTreeSet<String> = stmt
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    old.difference(&new).cloned().collect()
}

/// 冻结侧：可以写协议 3 表名的文件（相对 `store/gen4/`）→ 为什么。
const FROZEN_SIDE: &[(&str, &str)] = &[
    (
        "carry.rs",
        "迁移把协议 3 的本机状态（公钥、暂扣、检查点、本机媒体、位置）带进新代库，读的就是旧表",
    ),
    (
        "cmd/backup.rs",
        "整包备份里换代之前的复习数据（legacy_backup_import）先落进临时的协议 3 库再转译",
    ),
    ("compare.rs", "协议 3 投影与新代派生层逐类对拍"),
    ("dryrun.rs", "真实库干跑：旧库只读 → 临时新库 → 对拍"),
    ("legacy.rs", "冻结的旧代读入器"),
    (
        "media.rs",
        "迁移时从协议 3 的 sync2_media_at / sync2_media_seeded 灌 media_at 种子（`seed_legacy` 一处）",
    ),
    ("migrate.rs", "迁移编排：空间估算量旧缓存三张表的现有体积"),
];

#[test]
fn live_code_names_no_protocol_3_table() {
    let old = protocol_3_tables();
    for must in [
        "srs_review_logs",
        "srs_field_edits",
        "sync2_ops",
        "sync2_self",
    ] {
        assert!(old.contains(must), "table list parsed wrong: {old:?}");
    }
    assert!(!old.contains("srs_meta"), "srs_meta is a gen4 table too");
    let base = src_root().join("store").join("gen4");
    let allowed: BTreeMap<&str, &str> = FROZEN_SIDE.iter().copied().collect();
    let (mut scanned, mut bad, mut used) = (0, Vec::new(), BTreeSet::new());
    let test_mods = cfg_test_modules(&base);
    assert!(
        test_mods.contains(&base.join("parity.rs")),
        "cfg(test) modules parsed wrong: {test_mods:?}"
    );
    for p in rust_files(&base) {
        if is_test_file(&p, &test_mods) {
            continue;
        }
        scanned += 1;
        let name = rel(&base, &p);
        let hits = word_hits(&live_code(&std::fs::read_to_string(&p).unwrap()), &old);
        if hits.is_empty() {
            continue;
        }
        if allowed.contains_key(name.as_str()) {
            used.insert(name);
            continue;
        }
        for (n, t) in hits {
            bad.push(format!("store/gen4/{name}:{n}: {t}"));
        }
    }
    assert!(scanned > 60, "only {scanned} files scanned");
    assert!(
        bad.is_empty(),
        "live gen4 code names protocol 3 tables (only the frozen side may):\n{}",
        bad.join("\n")
    );
    let stale: Vec<&&str> = allowed.keys().filter(|k| !used.contains(**k)).collect();
    assert!(
        stale.is_empty(),
        "frozen-side entries that no longer touch old tables: {stale:?}"
    );
}

/// 空库上 [schema::install] 建出的对象与魔数的指纹：`application_id`，加上 `sqlite_schema` 里每个对象
/// `type|name|tbl_name|sql`（空白折成一个空格）按 (type, name) 排序后拼起来，取 blake3 的十六进制。
fn fingerprint() -> String {
    let conn = schema::open_in_memory().unwrap();
    let app: i32 = conn
        .query_row("PRAGMA application_id", [], |r| r.get(0))
        .unwrap();
    let mut text = format!("application_id={app}\n");
    let mut stmt = conn
        .prepare(
            "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_schema \
             WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })
        .unwrap();
    for row in rows {
        let (ty, name, tbl, sql) = row.unwrap();
        let sql = sql.split_whitespace().collect::<Vec<_>>().join(" ");
        text.push_str(&format!("{ty}|{name}|{tbl}|{sql}\n"));
    }
    blake3::hash(text.as_bytes()).to_hex().to_string()
}

#[test]
fn the_gen4_schema_is_frozen_at_its_number() {
    let numbers: Vec<i64> = FROZEN.iter().map(|(n, _)| *n).collect();
    assert!(
        numbers.windows(2).all(|w| w[0] < w[1]),
        "FROZEN must be strictly increasing: {numbers:?}"
    );
    let (last, recorded) = *FROZEN.last().unwrap();
    let now = fingerprint();
    assert_eq!(
        last,
        schema::SCHEMA,
        "SCHEMA is {} but the last frozen entry is {last}: append ({}, \"{now}\") to FROZEN",
        schema::SCHEMA,
        schema::SCHEMA
    );
    assert_eq!(
        recorded, now,
        "the gen4 schema changed without a SCHEMA bump: bump SCHEMA and append (new SCHEMA, \"{now}\") to FROZEN"
    );
}

/// `fn <name>(` 的函数体（到行首的 `}` 为止）。
fn fn_body<'a>(src: &'a str, head: &str) -> &'a str {
    let from = src.find(head).unwrap_or_else(|| panic!("missing {head}"));
    let rest = &src[from..];
    &rest[..rest.find("\n}\n").expect("function end")]
}

/// 匹配臂头里的命令名：缩进正好 [indent] 格、以字符串字面量或 `| "` 续行开头，到 `=>` 为止的全部字面量；
/// 返回 (命令名, 臂头 `=>` 之后到行尾的文字)。
fn arms(body: &str, indent: usize) -> Vec<(Vec<String>, String)> {
    let pad = " ".repeat(indent);
    let mut out = Vec::new();
    let mut cur: Option<Vec<String>> = None;
    for line in body.lines() {
        let at_indent = line.starts_with(&pad) && !line[indent..].starts_with(' ');
        let text = line.trim_start();
        if at_indent && text.starts_with('"') {
            // 新的臂头（rustfmt 把放不下一行的 `"a" | "b"` 折成同缩进的 `| "c"` 续行）。
            cur = Some(Vec::new());
        } else if !(at_indent && text.starts_with("| \"") && cur.is_some()) {
            cur = None;
            continue;
        }
        let (head, tail) = match line.find("=>") {
            Some(k) => (&line[..k], Some(line[k + 2..].trim().to_owned())),
            None => (line, None),
        };
        let names = cur.as_mut().unwrap();
        for (k, part) in head.split('"').enumerate() {
            if k % 2 == 1 {
                names.push(part.to_owned());
            }
        }
        if let Some(tail) = tail {
            out.push((cur.take().unwrap(), tail));
        }
    }
    out
}

#[test]
fn every_dispatched_command_is_registered_and_every_registered_one_has_an_arm() {
    let src = std::fs::read_to_string(src_root().join("store/gen4/dispatch.rs"))
        .unwrap()
        .replace("\r\n", "\n");
    let registered: BTreeSet<String> = arms(fn_body(&src, "pub fn wiring("), 8)
        .into_iter()
        .flat_map(|(names, _)| names)
        .collect();
    assert!(
        registered.len() > 120,
        "parsed too few registered commands: {}",
        registered.len()
    );
    let wired: BTreeSet<String> = registered
        .iter()
        .filter(|op| wiring(op) == Some(Wiring::Wired))
        .cloned()
        .collect();
    let handled: BTreeSet<String> = arms(fn_body(&src, "fn run("), 8)
        .into_iter()
        .flat_map(|(names, _)| names)
        .collect();
    assert!(
        handled.len() > 100,
        "parsed too few arms: {}",
        handled.len()
    );
    let unregistered: Vec<&String> = handled
        .iter()
        .filter(|op| wiring(op) != Some(Wiring::Wired))
        .collect();
    assert!(
        unregistered.is_empty(),
        "dispatcher arms not registered as Wired in dispatch::wiring: {unregistered:?}"
    );
    let armless: Vec<&String> = wired.difference(&handled).collect();
    assert!(
        armless.is_empty(),
        "registered as Wired but no arm in run: {armless:?}"
    );
}

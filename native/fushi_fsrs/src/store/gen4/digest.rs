//! 语义摘要（设计 §2.5、§4.1）：两台设备「同一个操作集合应当得到同一个状态」的校验值。覆盖的是语义状态，不是
//! 任何一张表的字节——没有旧因果上下文、没有本机的操作主键、没有别名表：
//!
//! - 每个寄存器**活着的写入**（没被支配的；胜者、冲突胜者、其余各算一类）的内容身份；
//! - 每条笔记当前的标签列表；
//! - 每张卡的日志 ID 集合；
//! - 每个实体的定义（身份记录的胜者）；
//! - 每个媒体名活着的绑定。
//!
//! 内容身份 = 操作号（设备 ID + seq）：同一个 dot 的多份迁移副本只有代表那一条是活着的，而代表是操作集合的函数
//! （操作号最小的）。已清除、被扣住、作者不可信的写入不在任何一项里，所以摘要不随「已清除的操作落没落成空洞」变。
//!
//! # 结构
//!
//! `dg_ix(col, ekind, ent, sum, n)`：每个实体一行——它名下各项的行哈希的回绕加法和（`sum`，16 字节小端）与项数。
//! 实体按**原值 ID** 记（不过别名表：摘要不能依赖别名规则的版本，也不能依赖两台设备各自的证据）。媒体名记在
//! [MEDIA] 这个假种类下。根 = 4096 个桶（按实体分）的值过一遍 blake3；桶可以单独拿出来比（[Index::digest_buckets]），
//! 缩小「哪些实体不一样」的范围。
//!
//! 逐条维护靠触发器：五张语义索引表上的行一变，就把那个实体记进 `dg_dirty`（静止时是空的），[Index::settle] 末尾只
//! 重算记下的实体。重建时不要这份逐行开销——[Index::rebuild_all] 先摘掉触发器、最后装回，再把全部实体算一遍；
//! 两条路算一个实体用的是同一个函数。
//!
//! 摘要串：`<根>@6:<版本向量哈希>`，本机扣着不可信设备的删除 / 清除时再接 `~<扣住集合的指纹>`（协议 3
//! `trust.rs::digest_vv_tag` 同义：只有 `@` 之后逐字相同的两台设备才比根）。

use rusqlite::{Connection, params};

use super::derive::{Index, R_LIVE, Ref};
use super::schema::sql;
use crate::sync2::id::Key;
use crate::sync2::op::EntKind;

/// 桶数（与协议 3 相同）。
pub const BUCKETS: usize = 4096;
/// 摘要串里版本向量部分的前缀：协议 3 是 `5:`，换了覆盖内容所以换号——两代的摘要永远不会被拿来比。
pub const VV_PREFIX: &str = "6:";
/// `dg_ix.ekind`：媒体名（不是实体种类）。
pub const MEDIA: i64 = 100;

const ROOT_DOMAIN: &[u8] = b"fushi-srs-digest-v3";

/// 标脏的触发器。`log_ix.win` / `ent_ix` 之外的列变化不改摘要覆盖的内容，所以只盯要紧的列。
const TRIGGERS: [(&str, &str, &str, &str); 5] = [
    ("reg", "reg_ix", "{r}.ekind, {r}.ent", "UPDATE OF state"),
    ("tag", "tag_ix", "3, {r}.note", "UPDATE OF state"),
    ("log", "log_ix", "4, {r}.card", ""),
    ("ent", "ent_ix", "{r}.kind, {r}.id", "UPDATE OF win"),
    ("media", "media_ix", "100, {r}.name", "UPDATE OF state"),
];

fn trigger_sql(on: bool) -> String {
    let mut out = String::new();
    for (name, table, what, update) in TRIGGERS {
        for (suffix, event, row) in [
            ("i", "INSERT", "new"),
            ("d", "DELETE", "old"),
            ("u", update, "new"),
        ] {
            if event.is_empty() {
                continue;
            }
            if on {
                let what = what.replace("{r}", row);
                out.push_str(&format!(
                    "CREATE TRIGGER IF NOT EXISTS dg_{name}_{suffix} AFTER {event} ON {table} BEGIN \
                     INSERT OR IGNORE INTO dg_dirty (col, ekind, ent) VALUES ({row}.col, {what}); END;\n"
                ));
            } else {
                out.push_str(&format!("DROP TRIGGER IF EXISTS dg_{name}_{suffix};\n"));
            }
        }
    }
    out
}

/// 装上 / 摘掉标脏的触发器（建库时装；[Index::rebuild_all] 期间摘掉）。
pub(super) fn set_triggers(conn: &Connection, on: bool) -> Result<(), String> {
    conn.execute_batch(&trigger_sql(on)).map_err(sql)
}

fn ref_bytes(r: &Ref) -> Vec<u8> {
    match r {
        Ref::Uuid(b) => {
            let mut v = vec![0u8];
            v.extend_from_slice(b);
            v
        }
        Ref::Text(s) => {
            let mut v = vec![1u8];
            v.extend_from_slice(s.as_bytes());
            v
        }
    }
}

/// 一项的哈希：tag 加若干段（每段前带长度，段与段不会粘连）。
fn item(tag: u8, parts: &[&[u8]]) -> u128 {
    let mut h = blake3::Hasher::new();
    h.update(&[tag]);
    for p in parts {
        h.update(&(p.len() as u32).to_le_bytes());
        h.update(p);
    }
    let mut b = [0u8; 16];
    b.copy_from_slice(&h.finalize().as_bytes()[..16]);
    u128::from_le_bytes(b)
}

/// 一个实体落在哪个桶：只看它是谁。
fn bucket_of(ekind: i64, ent: &Ref) -> usize {
    let h = blake3::hash(&[&[ekind as u8][..], &ref_bytes(ent)].concat());
    (usize::from(h.as_bytes()[0]) | usize::from(h.as_bytes()[1]) << 8) % BUCKETS
}

impl Index<'_, '_> {
    fn op_bytes(&self, k: i64) -> Result<Vec<u8>, String> {
        let id = self.t.id_of_key(k)?;
        let mut v = id.device.0.to_vec();
        v.extend_from_slice(&id.seq.to_le_bytes());
        Ok(v)
    }

    /// 一个实体名下的全部项：(回绕和, 项数)。
    fn digest_unit(&self, ekind: i64, ent: &Ref) -> Result<(u128, u64), String> {
        let conn = self.t.conn();
        let (mut sum, mut n) = (0u128, 0u64);
        let mut add = |x: u128| {
            sum = sum.wrapping_add(x);
            n += 1;
        };
        if ekind == MEDIA {
            let Ref::Text(name) = ent else {
                return Ok((0, 0));
            };
            let mut stmt = conn
                .prepare_cached(
                    "SELECT k, state FROM media_ix WHERE col = ?1 AND name = ?2 AND state >= ?3 ORDER BY k",
                )
                .map_err(sql)?;
            let rows: Vec<(i64, i64)> = stmt
                .query_map(params![self.col, name, R_LIVE], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (k, state) in rows {
                add(item(b'm', &[&[state as u8], &self.op_bytes(k)?]));
            }
            return Ok((sum, n));
        }
        {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT key, k, state FROM reg_ix \
                     WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state >= ?4 ORDER BY key, k",
                )
                .map_err(sql)?;
            let rows: Vec<(Vec<u8>, i64, i64)> = stmt
                .query_map(params![self.col, ekind, ent, R_LIVE], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (key, k, state) in rows {
                add(item(b'r', &[&key, &[state as u8], &self.op_bytes(k)?]));
            }
        }
        {
            let k: Option<i64> = conn
                .prepare_cached(
                    "SELECT MIN(k) FROM ent_ix WHERE col = ?1 AND id = ?2 AND kind = ?3 AND win = 1",
                )
                .map_err(sql)?
                .query_row(params![self.col, ent, ekind], |r| r.get(0))
                .map_err(sql)?;
            if let Some(k) = k {
                add(item(b'e', &[&self.op_bytes(k)?]));
            }
        }
        if ekind == EntKind::Note as i64 {
            let tags = self.tags_of(&Key::of(&ent.text()))?;
            if !tags.is_empty() {
                let parts: Vec<&[u8]> = tags.iter().map(String::as_bytes).collect();
                add(item(b't', &parts));
            }
        }
        if ekind == EntKind::Card as i64 {
            let mut stmt = conn
                .prepare_cached("SELECT DISTINCT id FROM log_ix WHERE col = ?1 AND card = ?2")
                .map_err(sql)?;
            let rows: Vec<Ref> = stmt
                .query_map(params![self.col, ent], |r| r.get(0))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for id in rows {
                add(item(b'l', &[&ref_bytes(&id)]));
            }
        }
        Ok((sum, n))
    }

    /// 重算记下的实体。返回算了几个。
    pub(super) fn digest_flush(&mut self) -> Result<u64, String> {
        let conn = self.t.conn();
        let dirty: Vec<(i64, Ref)> = {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT ekind, ent FROM dg_dirty WHERE col = ?1 ORDER BY ekind, ent",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        if dirty.is_empty() {
            return Ok(0);
        }
        for (ekind, ent) in &dirty {
            let (sum, n) = self.digest_unit(*ekind, ent)?;
            if n == 0 {
                conn.prepare_cached("DELETE FROM dg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3")
                    .map_err(sql)?
                    .execute(params![self.col, ekind, ent])
                    .map_err(sql)?;
            } else {
                conn.prepare_cached(
                    "INSERT INTO dg_ix (col, ekind, ent, sum, n) VALUES (?1, ?2, ?3, ?4, ?5) \
                     ON CONFLICT (col, ekind, ent) DO UPDATE SET sum = excluded.sum, n = excluded.n",
                )
                .map_err(sql)?
                .execute(params![self.col, ekind, ent, sum.to_le_bytes().as_slice(), n as i64])
                .map_err(sql)?;
            }
        }
        conn.prepare_cached("DELETE FROM dg_dirty WHERE col = ?1")
            .map_err(sql)?
            .execute([self.col])
            .map_err(sql)?;
        Ok(dirty.len() as u64)
    }

    /// 重建的收尾：把索引里出现过的实体全部记下（触发器这时是摘掉的），再走同一条重算。
    pub(super) fn digest_rebuild(&mut self) -> Result<u64, String> {
        let conn = self.t.conn();
        for q in [
            "SELECT DISTINCT col, ekind, ent FROM reg_ix WHERE col = ?1",
            "SELECT DISTINCT col, 3, note FROM tag_ix WHERE col = ?1",
            "SELECT DISTINCT col, 4, card FROM log_ix WHERE col = ?1",
            "SELECT DISTINCT col, kind, id FROM ent_ix WHERE col = ?1",
            "SELECT DISTINCT col, 100, name FROM media_ix WHERE col = ?1",
        ] {
            conn.execute(
                &format!("INSERT OR IGNORE INTO dg_dirty (col, ekind, ent) {q}"),
                [self.col],
            )
            .map_err(sql)?;
        }
        self.digest_flush()
    }

    /// 4096 个桶的值（每个是落进来的实体的哈希的回绕和）。
    pub fn digest_buckets(&self) -> Result<Vec<u128>, String> {
        let mut out = vec![0u128; BUCKETS];
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT ekind, ent, sum, n FROM dg_ix WHERE col = ?1")
            .map_err(sql)?;
        let mut rows = stmt.query([self.col]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let ekind: i64 = r.get(0).map_err(sql)?;
            let ent: Ref = r.get(1).map_err(sql)?;
            let sum: [u8; 16] = r.get(2).map_err(sql)?;
            let n: i64 = r.get(3).map_err(sql)?;
            let b = bucket_of(ekind, &ent);
            out[b] = out[b].wrapping_add(item(
                b'u',
                &[&[ekind as u8], &ref_bytes(&ent), &sum, &n.to_le_bytes()],
            ));
        }
        Ok(out)
    }

    /// 摘要的根（十六进制）。
    pub fn digest_root(&self) -> Result<String, String> {
        let mut h = blake3::Hasher::new();
        h.update(ROOT_DOMAIN);
        for b in self.digest_buckets()? {
            h.update(&b.to_le_bytes());
        }
        Ok(h.finalize().to_hex().to_string())
    }

    /// 摘要串（文件头）。只有收尾之后才有意义。
    pub fn digest(&self) -> Result<String, String> {
        let vv = self.t.applied(self.col)?;
        let mut out = format!("{}@{VV_PREFIX}{}", self.digest_root()?, vv.hash_hex());
        let held = self.distrusted()?;
        if !held.is_empty() {
            let mut h = blake3::Hasher::new();
            for id in &held {
                h.update(&id.device.0);
                h.update(&id.seq.to_le_bytes());
            }
            out.push('~');
            out.push_str(&h.finalize().to_hex()[..16]);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::gen4::op::tests::{id, native_edit, sample_log};
    use crate::gen4::op::{Body4, Edit4, Log4};
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, native, op, with};
    use crate::store::gen4::truth::{TRUST_PENDING, Truth};

    fn edit(entity: u8, key: &str, value: &str) -> Body4 {
        Body4::Edit(Edit4 {
            entity: Key::Uuid(id(entity)),
            key: key.to_owned(),
            value: json!(value).to_string(),
            ..native_edit()
        })
    }

    fn log(n: u8, card: u8) -> Body4 {
        Body4::Log(Log4 {
            id: Key::Uuid(id(n)),
            card: Key::Uuid(id(card)),
            note: None,
            ..sample_log()
        })
    }

    fn tag(note: u8, tag: &str) -> Body4 {
        Body4::TagAdd {
            note: Key::Uuid(id(note)),
            tag: tag.to_owned(),
        }
    }

    /// 两台设备各自的日志。
    fn logs() -> [Vec<Body4>; 2] {
        [
            vec![
                edit(3, "a", "1"),
                tag(3, "x"),
                log(0x51, 8),
                edit(3, "a", "2"),
                Body4::Media {
                    name: "m.png".into(),
                    sha256: [1; 32],
                    size: 3,
                },
            ],
            vec![
                edit(3, "a", "other"),
                edit(5, "b", "1"),
                log(0x52, 8),
                tag(3, "y"),
            ],
        ]
    }

    /// 按 [order]（true = 取第一台的下一条）灌进去，每条收尾或最后一起收尾。
    fn run(
        order: &[bool],
        each: bool,
        then: impl FnOnce(&Truth<'_>, &mut Index<'_, '_>, i64),
    ) -> String {
        with(|t, col| {
            let root = t
                .tx(|t| {
                    let mut ix = Index::new(t, col);
                    let logs = logs();
                    let mut at = [0usize; 2];
                    for first in order {
                        let d = usize::from(!*first);
                        let seq = at[d] as u64 + 1;
                        native(
                            t,
                            &mut ix,
                            col,
                            &op(
                                0xa1 + d as u8,
                                seq,
                                100 * (d as i64 + 1) + seq as i64,
                                &[],
                                &logs[d][at[d]],
                            ),
                        );
                        at[d] += 1;
                        if each {
                            ix.settle()?;
                        }
                    }
                    ix.settle()?;
                    then(t, &mut ix, col);
                    ix.settle()?;
                    assert_eq!(
                        t.conn()
                            .query_row("SELECT COUNT(*) FROM dg_dirty", [], |r| r.get::<_, i64>(0))
                            .unwrap(),
                        0
                    );
                    ix.digest()
                })
                .unwrap();
            assert_rebuild_is_identity(t, col);
            let again = t.tx(|t| Index::new(t, col).digest()).unwrap();
            assert_eq!(root, again);
            root
        })
    }

    const A_THEN_B: [bool; 9] = [true, true, true, true, true, false, false, false, false];
    const MIXED: [bool; 9] = [false, true, false, true, true, false, true, false, true];

    #[test]
    fn the_digest_is_a_function_of_the_op_set_not_of_arrival_order() {
        let base = run(&A_THEN_B, false, |_, _, _| {});
        assert!(base.contains("@6:"), "{base}");
        assert!(!base.contains('~'));
        assert_eq!(base, run(&A_THEN_B, true, |_, _, _| {}));
        assert_eq!(base, run(&MIXED, true, |_, _, _| {}));
        assert_eq!(base, run(&MIXED, false, |_, _, _| {}));
    }

    #[test]
    fn the_digest_follows_the_semantic_state() {
        let base = run(&A_THEN_B, false, |_, _, _| {});
        let root = |s: &str| s.split('@').next().unwrap().to_owned();
        // 多一条写入（哪怕值相同）、多一个标签、多一条日志：根都变。
        let more = |b: Body4| {
            run(&A_THEN_B, false, move |t, ix, col| {
                native(t, ix, col, &op(0xa3, 1, 9000, &[], &b));
            })
        };
        let all = [
            more(edit(3, "a", "2")),
            more(tag(3, "z")),
            more(log(0x53, 8)),
            more(edit(6, "c", "1")),
        ];
        for (i, a) in all.iter().enumerate() {
            assert_ne!(root(a), root(&base));
            for b in &all[i + 1..] {
                assert_ne!(root(a), root(b));
            }
        }
        // 同一条日志的另一份（同一个日志 ID、同一张卡）：日志 ID 集合没变，根不变；版本向量变了。
        let copy = more(log(0x51, 8));
        assert_eq!(root(&copy), root(&base));
        assert_ne!(copy, base);
        // 见过全部的一条写入：换了胜者，根变。
        let seen = run(&A_THEN_B, false, |t, ix, col| {
            native(
                t,
                ix,
                col,
                &op(0xa3, 1, 1, &[(0xa1, 5), (0xa2, 4)], &edit(3, "a", "2")),
            );
        });
        assert_ne!(root(&seen), root(&all[0]));
    }

    #[test]
    fn purged_content_is_out_whether_or_not_it_became_a_hole_and_distrust_tags_the_digest() {
        let purge = Body4::Purge {
            kind: crate::sync2::op::EntKind::Note,
            entity: Key::Uuid(id(3)),
        };
        let marked = run(&A_THEN_B, false, |t, ix, col| {
            native(t, ix, col, &op(0xa3, 1, 9000, &[], &purge));
        });
        let executed = run(&A_THEN_B, false, |t, ix, col| {
            native(t, ix, col, &op(0xa3, 1, 9000, &[], &purge));
            assert!(ix.execute_purges().unwrap() > 0);
        });
        assert_eq!(marked, executed);
        let base = run(&A_THEN_B, false, |_, _, _| {});
        assert_ne!(marked.split('@').next(), base.split('@').next());
        // 本机不信任清除的作者：清除不执行，根回到没有清除时的样子，摘要串带扣住集合的指纹。
        let distrusted = run(&A_THEN_B, false, |t, ix, col| {
            native(t, ix, col, &op(0xa3, 1, 9000, &[], &purge));
            t.set_trust(col, &id(0xa3), Some(TRUST_PENDING), 1).unwrap();
            ix.trust_changed();
        });
        assert_eq!(distrusted.split('@').next(), base.split('@').next());
        let tail = distrusted.split('~').nth(1).expect("fingerprint");
        assert_eq!(tail.len(), 16);
        assert_ne!(distrusted, base);
    }
}

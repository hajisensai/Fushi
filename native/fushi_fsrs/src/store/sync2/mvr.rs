//! 「因果优先、并发才比 HLC」的标量寄存器（设计 §5.1 / §5.2）：媒体名 → 内容绑定、`MediaAt` 的在 / 不在、
//! 笔记标签的顺序提示。
//!
//! 以前这三个寄存器纯按 HLC 大者胜。HLC 在本机收到远端操作后推进（`observe_remote`）就与因果一致，但两类情况
//! 仍会让「因果上更晚的写」HLC 更小：远端时钟超前超过 [crate::sync2::hlc::MAX_AHEAD_MS]（照收、打标，但不把本机
//! 时钟拽过去），以及升级前从没推进过时钟的老设备写下的历史操作。纯 HLC 规则下慢钟设备看过对方的值之后再写，
//! 照样输——绑定改不回来、`MediaAt` 每轮重传。
//!
//! 规则：每个寄存器保存「没被任何已知写入因果覆盖」的写入（反链，通常只有一条）。新写入覆盖（它的上下文见过）的
//! 旧写入被移除；它自己被已存写入覆盖就不进来；剩下的才是真正并发的，按 HLC 取最大者为当前值。反链是操作集合的
//! 函数（覆盖关系是偏序：上下文是整个已应用版本向量，向下封闭、可传递），所以结果与到达顺序无关，各设备逐位相同。
//! 只存 `(寄存器, 设备, seq)`：HLC 与上下文按主键从 `sync2_ops` 取，被撤出的操作（换身份重签发）自动不再参与。

use std::sync::Arc;

use rusqlite::{params, Connection};

use super::sql;
use crate::sync2::codec::Reader;
use crate::sync2::id::Id;
use crate::sync2::op::Op;
use crate::sync2::vv::{OpId, Vv};

/// 反链里的一条写入。
#[derive(Clone, Debug)]
pub(crate) struct Write {
    pub id: OpId,
    pub wall: i64,
    pub logical: i64,
    pub deps: Arc<Vv>,
}

impl Write {
    fn stamp(&self) -> (i64, i64, [u8; 16]) {
        (self.wall, self.logical, self.id.device.0)
    }
}

/// [x] 因果上覆盖（见过）[y]：同一设备按 seq，别的设备看 [x] 的上下文。
pub(crate) fn covers(x_id: &OpId, x_deps: &Vv, y: &OpId) -> bool {
    if x_id.device == y.device {
        x_id.seq > y.seq
    } else {
        x_deps.get(&y.device) >= y.seq
    }
}

fn id_of(b: Vec<u8>) -> Result<Id, String> {
    Ok(Id(b.try_into().map_err(|_| "bad id blob".to_string())?))
}

/// 一个寄存器当前的反链。
pub(crate) fn writes(conn: &Connection, profile: &str, reg: &str) -> Result<Vec<Write>, String> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT m.device, m.seq, o.wall, o.logical, d.vv FROM sync2_mvr m \
             JOIN sync2_ops o ON o.profile_uid = m.profile_uid AND o.device = m.device AND o.seq = m.seq \
             JOIN sync2_deps d ON d.id = o.deps WHERE m.profile_uid = srs_id(?1) AND m.reg = ?2",
        )
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![profile, reg], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?, r.get::<_, Vec<u8>>(4)?))
        })
        .map_err(sql)?;
    let mut out = Vec::new();
    for row in rows {
        let (d, seq, wall, logical, vv) = row.map_err(sql)?;
        let deps = Vv::read(&mut Reader::new(&vv)).map_err(|e| e.to_string())?;
        out.push(Write { id: OpId { device: id_of(d)?, seq: seq as u64 }, wall, logical, deps: Arc::new(deps) });
    }
    Ok(out)
}

/// 并入一条写入，返回并入后的当前值（反链里 HLC 最大的写入）。重复并入同一条无副作用。
pub(crate) fn write(conn: &Connection, profile: &str, reg: &str, op: &Op) -> Result<Write, String> {
    let mut set = writes(conn, profile, reg)?;
    let me = Write { id: op.id, wall: op.hlc.wall, logical: i64::from(op.hlc.logical), deps: op.deps.clone() };
    let known = set.iter().any(|w| w.id == op.id);
    let dominated = set.iter().any(|w| covers(&w.id, &w.deps, &op.id));
    if !known && !dominated {
        let (gone, kept): (Vec<Write>, Vec<Write>) = set.into_iter().partition(|w| covers(&me.id, &me.deps, &w.id));
        let mut del = conn
            .prepare_cached("DELETE FROM sync2_mvr WHERE profile_uid = srs_id(?1) AND reg = ?2 AND device = ?3 AND seq = ?4")
            .map_err(sql)?;
        for w in &gone {
            del.execute(params![profile, reg, w.id.device.0.to_vec(), w.id.seq as i64]).map_err(sql)?;
        }
        set = kept;
        conn.prepare_cached("INSERT OR IGNORE INTO sync2_mvr (profile_uid, reg, device, seq) VALUES (srs_id(?1), ?2, ?3, ?4)")
            .map_err(sql)?
            .execute(params![profile, reg, op.id.device.0.to_vec(), op.id.seq as i64])
            .map_err(sql)?;
        set.push(me);
    }
    set.into_iter().max_by_key(Write::stamp).ok_or_else(|| "mvr: empty register after write".to_owned())
}

/// 从日志重建三个寄存器的反链与投影（schema V10 升级时跑一次；幂等）：反链是操作集合的函数，按任意顺序并入
/// 结果相同。只对当前值变了的寄存器改投影；标签顺序变了的笔记顺手刷新合成的 `tags` 行。
pub(crate) fn rebuild(conn: &Connection) -> Result<(), String> {
    use crate::sync2::op::{Body, KIND_MEDIA, KIND_MEDIA_AT};
    let profiles: Vec<String> = conn
        .prepare("SELECT srs_idt(profile_uid) AS profile_uid FROM sync2_self")
        .map_err(sql)?
        .query_map([], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    conn.execute("DELETE FROM sync2_mvr", []).map_err(sql)?;
    for profile in &profiles {
        let mut ids: Vec<(Vec<u8>, i64)> = conn
            .prepare("SELECT device, seq FROM sync2_ops WHERE profile_uid = srs_id(?1) AND kind IN (?2, ?3) AND purged = 0")
            .map_err(sql)?
            .query_map(params![profile, i64::from(KIND_MEDIA), i64::from(KIND_MEDIA_AT)], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let tag_ops: Vec<(Vec<u8>, i64)> = conn
            .prepare("SELECT device, seq FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = 'note' AND what IN ('#tag', 'tags')")
            .map_err(sql)?
            .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        ids.extend(tag_ops);
        // (寄存器, 投影落点)：寄存器全部并完再落投影。
        let mut media: std::collections::BTreeSet<String> = Default::default();
        let mut at: std::collections::BTreeSet<(String, String)> = Default::default();
        let mut notes: std::collections::BTreeSet<String> = Default::default();
        for (d, seq) in ids {
            let id = OpId { device: id_of(d)?, seq: seq as u64 };
            let Some(op) = super::load_op(conn, profile, &id)? else { continue };
            match op.body() {
                Ok(Body::Media { name, .. }) => {
                    write(conn, profile, &reg("m", &[&name]), &op)?;
                    media.insert(name);
                }
                Ok(Body::MediaAt { location, names, .. }) => {
                    for n in names {
                        write(conn, profile, &reg("a", &[&location, &n]), &op)?;
                        at.insert((location.clone(), n));
                    }
                }
                Ok(Body::TagOrder { note, .. }) => {
                    let n = note.text();
                    write(conn, profile, &reg("t", &[&n]), &op)?;
                    notes.insert(n);
                }
                Ok(Body::Edit(e)) if e.kind == crate::sync2::op::EntKind::Note && e.key == "tags" => {
                    let n = e.entity.text();
                    write(conn, profile, &reg("t", &[&n]), &op)?;
                    notes.insert(n);
                }
                _ => {}
            }
        }
        let top = |r: &str| -> Result<Option<Write>, String> { Ok(writes(conn, profile, r)?.into_iter().max_by_key(Write::stamp)) };
        for name in &media {
            if let Some(w) = top(&reg("m", &[name]))? {
                super::land_media_binding(conn, profile, name, &w)?;
            }
        }
        for (loc, name) in &at {
            if let Some(w) = top(&reg("a", &[loc, name]))? {
                super::media::land_media_at(conn, profile, loc, name, &w, None)?;
            }
        }
        for note in &notes {
            if let Some(w) = top(&reg("t", &[note]))? {
                if super::semantics::land_tag_order(conn, profile, note, &w, None)? {
                    super::semantics::refresh_tags_row(conn, profile, note, &mut super::Touched::default())?;
                }
            }
        }
    }
    Ok(())
}

/// 寄存器键：种类前缀 + 各部分（用 0x1f 分隔，名字里不会出现）。
pub(crate) fn reg(kind: &str, parts: &[&str]) -> String {
    let mut s = String::from(kind);
    for p in parts {
        s.push('\u{1f}');
        s.push_str(p);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn covers_is_by_seq_on_one_device_and_by_context_across_devices() {
        let a = Id([1; 16]);
        let b = Id([2; 16]);
        let mut deps = Vv::new();
        deps.set(b, 5);
        assert!(covers(&OpId { device: a, seq: 3 }, &deps, &OpId { device: a, seq: 2 }));
        assert!(!covers(&OpId { device: a, seq: 3 }, &deps, &OpId { device: a, seq: 3 }));
        assert!(covers(&OpId { device: a, seq: 1 }, &deps, &OpId { device: b, seq: 5 }));
        assert!(!covers(&OpId { device: a, seq: 1 }, &deps, &OpId { device: b, seq: 6 }));
    }
}

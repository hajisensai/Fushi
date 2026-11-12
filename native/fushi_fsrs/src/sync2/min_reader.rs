//! 操作内容要求的最低读者版本（设计 §8；head 的 `minReader` 按它声明）。
//!
//! head 的 `minReader` 比读者的协议新，读者就不收这台设备、整轮报需要升级（store/sync2/transport.rs `plan`；旧版本
//! 冻结的行为是整轮停写，不是只跳过那一台）。以前它是常量：哪怕一台设备只写了旧读者完全读得懂的内容，只要换了新版本，
//! 就会把所有旧设备整轮停下。现在按**本机实际写出的内容**声明：每条本机操作经 [min_reader_of] 查表，声明值只增不减
//! （store/sync2/min_reader.rs）。
//!
//! **规则：只要改变了旧读者对某条操作的投影，就必须在这里给它声明更高的版本。**「投影」= 旧读者解出的种类 / 字段
//! （[super::op::Body::decode]）与日志的意图（store/sync2/mod.rs `intent_of`）。表按语义特征建，不按 kind：同一个 kind
//! 里加了新语义（新的日志种类串、新意图、新标志位、新实体种类、追加的字段、新骨架形态），旧读者照样收、照样按旧语义
//! 投影错，只看 kind 抓不到。
//!
//! 不在这张表的范围里：读者自己的派生规则（日志重放 / 选取规则，例如 history.rs 的成组规则）。那是读者一侧的版本，
//! 由摘要前缀 `VV_PREFIX`（store/sync2/digest.rs）区分；内容字节没变，旧读者照旧按自己的规则投影、只是摘要不比。
//!
//! 守卫：`Body` / `Intent` / `EntKind` 的 match 都不带通配分支（加变体编译不过，逼着来这里登记）；
//! 测试枚举全部种类码、日志种类串、复习类型、来源与标志位，并用冻结的 v3.3.0 解码 + 意图副本（`min_reader_v330.rs`）
//! 逐位对拍：凡是这里声明 ≤ 3 的内容，v3.3.0 读者解出来的必须与本版本完全相同。

use super::op::{
    Body, EntKind, Intent, LogBody, MEDIA_AT_PRESENT, MEDIA_AT_SEEDED, MEDIA_AT_SUSPECT, Op,
    skeleton_body,
};
use super::segment::{CONTENT_FLOOR, PROTOCOL};

/// 本版本不认识的内容：至少要比本版本新的读者。只会出现在别的设备写的、更新版本的内容上；本机写出的操作走不到这里
/// （store/sync2/min_reader.rs 遇到它直接报错，不让它悄悄抬高声明把所有设备停下）。
pub const NEWER_THAN_ME: u32 = PROTOCOL + 1;

/// [Body::MediaAt] 已知的标志位（三位都在 v3.3.0 之前就有了；旧读者把 [MEDIA_AT_SUSPECT] 当「不在」，不拉也不删，
/// 见 op.rs 该常量的说明）。
pub const MEDIA_AT_KNOWN_FLAGS: u8 = MEDIA_AT_PRESENT | MEDIA_AT_SEEDED | MEDIA_AT_SUSPECT;

/// 日志种类串 → 它的语义从哪个读者版本起才有。表外的串所有版本都按「不认识的种类」处理（history.rs `Kind::Unknown`，
/// 重放意图 [Intent::Absolute]），旧读者与本版本投影相同，按地板值。给一个新的种类串赋予语义时必须在这里登记更高的版本
/// （测试 `every_history_kind_is_in_the_table` 钉住：history.rs 认识的串都要在表里）。
pub const LOG_KIND_READERS: [(&str, u32); 6] = [
    ("review", CONTENT_FLOOR),
    ("manual", CONTENT_FLOOR),
    ("reschedule", CONTENT_FLOOR),
    ("importAnchor", CONTENT_FLOOR),
    ("handOff", CONTENT_FLOOR),
    ("undo", CONTENT_FLOOR),
];

/// 复习类型串（重放与意图推断看 learn / review / relearn）。规则同 [LOG_KIND_READERS]。
pub const RTYPE_READERS: [(&str, u32); 6] = [
    ("learn", CONTENT_FLOOR),
    ("review", CONTENT_FLOOR),
    ("relearn", CONTENT_FLOOR),
    ("filtered", CONTENT_FLOOR),
    ("manual", CONTENT_FLOOR),
    ("rescheduled", CONTENT_FLOOR),
];

/// 来源串（选取与意图推断只看 fushi / anki）。规则同 [LOG_KIND_READERS]。
pub const ORIGIN_READERS: [(&str, u32); 2] = [("fushi", CONTENT_FLOOR), ("anki", CONTENT_FLOOR)];

fn lookup(table: &[(&str, u32)], s: &str) -> u32 {
    table
        .iter()
        .find(|(k, _)| *k == s)
        .map_or(CONTENT_FLOOR, |(_, v)| *v)
}

/// 实体种类码。五种都是协议 1 就有的。新加一种：旧读者解码直接报错（op.rs `EntKind::from_code`），必须声明更高版本。
pub fn ent_kind_min_reader(k: EntKind) -> u32 {
    match k {
        EntKind::Profile | EntKind::Deck | EntKind::NoteType | EntKind::Note | EntKind::Card => {
            CONTENT_FLOOR
        }
    }
}

/// 日志意图（存进 `sync2_log_meta` 的意图码）。六种都是 v3.3.0 就有的；新加一种意图码旧读者解码报错，必须声明更高版本。
pub fn intent_min_reader(i: &Intent) -> u32 {
    match i {
        Intent::Absolute
        | Intent::Answer
        | Intent::SetDue { .. }
        | Intent::Reset
        | Intent::Reschedule
        | Intent::HandOff { .. } => CONTENT_FLOOR,
    }
}

fn log_min_reader(l: &LogBody) -> u32 {
    lookup(&LOG_KIND_READERS, &l.kind)
        .max(lookup(&RTYPE_READERS, &l.rtype))
        .max(lookup(&ORIGIN_READERS, &l.origin))
        .max(intent_min_reader(&l.intent))
}

/// 一条已解码内容要求的最低读者版本（本机写操作时用：载荷就是它的规范编码，不会带多出来的字节）。
pub fn min_reader_of_body(body: &Body) -> u32 {
    match body {
        Body::Entity { kind, .. } | Body::Purge { kind, .. } => ent_kind_min_reader(*kind),
        Body::Edit(e) => ent_kind_min_reader(e.kind),
        Body::Log(l) => log_min_reader(l),
        Body::MediaAt { flags, .. } => {
            if flags & !MEDIA_AT_KNOWN_FLAGS == 0 {
                CONTENT_FLOOR
            } else {
                NEWER_THAN_ME
            }
        }
        // 协议 3 的内容（BUG-4005）：协议 2 读者不认，地板值本来就是 3。
        Body::Dedup { .. } | Body::Duplicate { .. } => CONTENT_FLOOR,
        Body::TagAdd { .. }
        | Body::TagRemove { .. }
        | Body::TagOrder { .. }
        | Body::Checkpoint { .. }
        | Body::Media { .. }
        | Body::DeckAlias { .. }
        | Body::LegacyUnknown { .. }
        | Body::Purged => CONTENT_FLOOR,
        Body::Unknown => NEWER_THAN_ME,
    }
}

/// 一条操作（含骨架）要求的最低读者版本。解不开 / 本版本不认识的种类 / 已知种类后面多出本版本不读的字节
/// （更新版本追加的字段，本版本与更旧的读者都会忽略）：[NEWER_THAN_ME]。
pub fn min_reader_of(op: &Op) -> u32 {
    if op.purged {
        return match skeleton_body(&op.payload) {
            Ok(b) => min_reader_of_body(&b),
            Err(_) => NEWER_THAN_ME,
        };
    }
    let Ok(body) = Body::decode(op.kind, &op.payload) else {
        return NEWER_THAN_ME;
    };
    if matches!(body, Body::Unknown) || body.encode().len() < op.payload.len() {
        return NEWER_THAN_ME;
    }
    min_reader_of_body(&body)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Arc;

    use super::super::hlc::Hlc;
    use super::super::id::{Id, Key};
    use super::super::op::{
        self, EditBody, KIND_DEDUP, KIND_LOG, KIND_TAG_ADD, LegacyStamp, tests::sample_log,
    };
    use super::super::vv::{OpId, Vv};
    use super::*;

    /// 本版本认识的全部种类码（`Body::decode` 不回 `Unknown` 的那些）。
    fn known_kinds() -> Vec<u16> {
        (0..=255u16)
            .filter(|k| !matches!(Body::decode(*k, &[]), Ok(Body::Unknown)))
            .collect()
    }

    pub(crate) fn op_of(kind: u16, payload: Vec<u8>, purged: bool) -> Op {
        Op {
            id: OpId {
                device: Id([1; 16]),
                seq: 1,
            },
            hlc: Hlc {
                wall: 1,
                logical: 0,
                device: Id([1; 16]),
            },
            deps: Arc::new(Vv::new()),
            kind,
            schema: op::SCHEMA,
            payload: payload.into(),
            purged,
        }
    }

    pub(crate) fn op_of_body(b: &Body) -> Op {
        op_of(b.kind(), b.encode(), false)
    }

    /// 每一种语义特征至少一条样本（种类、实体种类、日志种类串 / 复习类型 / 来源 / 意图、标志位、骨架形态）。
    pub(crate) fn feature_samples() -> Vec<Op> {
        let mut bodies = Vec::new();
        for k in EntKind::ALL {
            bodies.push(Body::Entity {
                kind: k,
                id: Key::of("e"),
                data: "{}".into(),
            });
            bodies.push(Body::Edit(EditBody {
                kind: k,
                entity: Key::Uuid(Id([3; 16])),
                key: "deleted".into(),
                value: "true".into(),
                machine: false,
                ts: 1,
                legacy: None,
            }));
            bodies.push(Body::Purge {
                kind: k,
                entity: Key::of("e"),
            });
        }
        bodies.push(Body::Edit(EditBody {
            kind: EntKind::Note,
            entity: Key::of("n"),
            key: "f".into(),
            value: "null".into(),
            machine: true,
            ts: 0,
            legacy: Some(LegacyStamp {
                writer: "w".into(),
                seq: 4,
                ctx_json: "{}".into(),
                hlc: "1:0:w".into(),
                server_time: Some(9),
            }),
        }));
        let intents = [
            Intent::Absolute,
            Intent::Answer,
            Intent::SetDue { due_day: -3 },
            Intent::Reset,
            Intent::Reschedule,
            Intent::HandOff { to_anki: true },
            Intent::HandOff { to_anki: false },
        ];
        let strs = |t: &[(&str, u32)]| -> Vec<String> {
            t.iter()
                .map(|(s, _)| (*s).to_owned())
                .chain(["somethingNew".to_owned()])
                .collect()
        };
        for kind in strs(&LOG_KIND_READERS) {
            for intent in &intents {
                bodies.push(Body::Log(LogBody {
                    kind: kind.clone(),
                    intent: intent.clone(),
                    res: Some(r#"{"queue":"review"}"#.into()),
                    ..sample_log()
                }));
            }
        }
        for rtype in strs(&RTYPE_READERS) {
            bodies.push(Body::Log(LogBody {
                rtype,
                ..sample_log()
            }));
        }
        for origin in strs(&ORIGIN_READERS) {
            bodies.push(Body::Log(LogBody {
                origin,
                note: None,
                revokes: Some(Key::of("x")),
                rating: None,
                params: None,
                alg: None,
                anki_id: Some(-7),
                legacy_hlc: Some("1:0:w".into()),
                legacy_server_time: Some(1),
                extra: r#"{"restoreOf":"a"}"#.into(),
                ..sample_log()
            }));
        }
        for flags in 0..=MEDIA_AT_KNOWN_FLAGS {
            bodies.push(Body::MediaAt {
                location: "drive:x/media".into(),
                flags,
                names: vec!["a.mp3".into()],
            });
        }
        bodies.extend([
            Body::TagAdd {
                note: Key::of("n"),
                tag: "t".into(),
            },
            Body::TagRemove {
                note: Key::of("n"),
                tag: "t".into(),
            },
            Body::TagOrder {
                note: Key::of("n"),
                tags: vec!["b".into(), "a".into()],
            },
            Body::Checkpoint {
                name: "a".into(),
                reason: "import".into(),
            },
            Body::Media {
                name: "a.mp3".into(),
                sha256: [9; 32],
                size: 77,
            },
            Body::DeckAlias {
                from: Key::of("b"),
                to: Key::of("a"),
            },
            Body::LegacyUnknown { json: "{}".into() },
            Body::Dedup {
                pairs: vec![
                    (
                        2,
                        OpId {
                            device: Id([5; 16]),
                            seq: 9,
                        },
                    ),
                    (
                        7,
                        OpId {
                            device: Id([4; 16]),
                            seq: 1,
                        },
                    ),
                ],
            },
        ]);
        let mut ops: Vec<Op> = bodies.iter().map(op_of_body).collect();
        // 骨架：彻底清除（32 字节）与副本骨架（带 / 不带旧戳）。
        let edit = op_of_body(&bodies[1]);
        let twin = OpId {
            device: Id([6; 16]),
            seq: 3,
        };
        ops.push(edit.purge());
        ops.push(edit.duplicate(twin).unwrap());
        let legacy_edit = ops
            .iter()
            .find(|o| {
                matches!(
                    o.body(),
                    Ok(Body::Edit(EditBody {
                        legacy: Some(_),
                        ..
                    }))
                )
            })
            .cloned()
            .unwrap();
        ops.push(legacy_edit.duplicate(twin).unwrap());
        let log = op_of_body(&Body::Log(sample_log()));
        ops.push(log.purge());
        ops.push(log.duplicate(twin).unwrap());
        ops
    }

    #[test]
    fn every_known_kind_and_entity_kind_has_an_entry() {
        // 新加种类码：Body::decode 认识它就会出现在这里，min_reader_of_body 的 match 不带通配分支、编译即逼着登记。
        assert_eq!(known_kinds(), (1..=13).collect::<Vec<u16>>());
        assert_eq!(op::KIND_DEDUP, 13);
        let samples = feature_samples();
        for k in known_kinds() {
            assert!(
                samples.iter().any(|o| o.kind == k && !o.purged),
                "kind {k} has no sample"
            );
        }
        for k in EntKind::ALL {
            assert_eq!(ent_kind_min_reader(k), CONTENT_FLOOR);
        }
    }

    #[test]
    fn every_history_kind_is_in_the_table() {
        // history.rs 认识的日志种类、op.rs 编码表里的种类 / 复习类型 / 来源都要在表里有条目。
        for s in op::LOG_KINDS {
            assert!(LOG_KIND_READERS.iter().any(|(k, _)| *k == s), "{s}");
            assert_ne!(
                crate::history::Kind::parse(s),
                crate::history::Kind::Unknown
            );
        }
        for (s, _) in LOG_KIND_READERS {
            assert_ne!(
                crate::history::Kind::parse(s),
                crate::history::Kind::Unknown,
                "{s}"
            );
        }
        for s in op::RTYPES {
            assert!(RTYPE_READERS.iter().any(|(k, _)| *k == s), "{s}");
        }
        for s in op::ORIGINS {
            assert!(ORIGIN_READERS.iter().any(|(k, _)| *k == s), "{s}");
        }
    }

    #[test]
    fn everything_this_version_writes_is_readable_by_protocol_three() {
        // 地板值 3（不是 2）：协议 2 的读者按旧派生规则投影、摘要前缀不同又永远不比，放进来会静默分叉。
        assert_eq!(CONTENT_FLOOR, 3);
        for o in feature_samples() {
            assert_eq!(min_reader_of(&o), CONTENT_FLOOR, "{:?}", o.body());
            if !o.purged {
                assert_eq!(min_reader_of_body(&o.body().unwrap()), CONTENT_FLOOR);
            }
        }
    }

    #[test]
    fn content_this_version_cannot_characterise_needs_a_newer_reader() {
        // 不认识的种类、解不开的载荷、已知种类后面追加的字段、未知标志位、未知骨架形态。
        assert_eq!(
            min_reader_of(&op_of(14, vec![1, 2, 3], false)),
            NEWER_THAN_ME
        );
        assert_eq!(
            min_reader_of(&op_of(KIND_LOG, vec![9], false)),
            NEWER_THAN_ME
        );
        let mut tag = Body::TagAdd {
            note: Key::of("n"),
            tag: "t".into(),
        }
        .encode();
        tag.extend_from_slice(&[1, 2, 3]);
        assert_eq!(
            min_reader_of(&op_of(KIND_TAG_ADD, tag, false)),
            NEWER_THAN_ME
        );
        let flags = Body::MediaAt {
            location: "l".into(),
            flags: 8 | MEDIA_AT_PRESENT,
            names: vec![],
        };
        assert_eq!(min_reader_of(&op_of_body(&flags)), NEWER_THAN_ME);
        let mut skel = vec![0u8; 32];
        skel.push(2); // 副本骨架版本 2：本版本不认识
        assert_eq!(min_reader_of(&op_of(KIND_DEDUP, skel, true)), NEWER_THAN_ME);
        assert_eq!(min_reader_of_body(&Body::Unknown), NEWER_THAN_ME);
        assert!(NEWER_THAN_ME > PROTOCOL);
    }
}

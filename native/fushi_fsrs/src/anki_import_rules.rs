//! 从 Anki 导入的日志的 HLC（铁律 C：导入事件的全部内容只由来源数据决定）。Dart 的对应实现是
//! `packages/fushi_srs/lib/src/anki_import_rules.dart` 的 `srsImportedRevlogHlc` / `srsImportAnchorHlc`，两边按同一份
//! 向量 `native/fushi_fsrs/src/anki_source_hlc_vectors.json` 对拍（Dart 侧
//! `packages/fushi_srs/test/anki_source_hlc_vectors_test.dart`）。
//!
//! 协议 3 的卡片历史规则（`crate::history`，冻结）读这个 HLC 做三件事：同一次 Anki 复习落在血统里不同卡上的几份副本
//! 归成一个事件（`EventKey`，BUG-4218 / BUG-4254：Anki 来源不比卡，只比 HLC 等内容）、统计跨组去重（`AnkiEvent`）、
//! 排序（`SortKey`：更早发生的 Anki 复习排在更晚的原生复习之前，锚点 counter = 1 排在同一毫秒的来源 revlog 之后）。
//!
//! 新代的原生日志不带旧 HLC（设计 §3.4，`gen4/op.rs` `Log4`），排序键默认是操作自己的 HLC。Anki 来源的日志是例外：
//! 它的 HLC 由来源数据派生（本文件），派生值只依赖操作体，每台设备算出来一样。
//! 新代投影日志（`store/gen4/cache.rs` `log_body`）与写回包（`store/gen4/cmd/writes.rs` 的 `logHlcs`）都只经这里。

/// 导入事件的写入者（Dart `srsAnkiWriterId`）。
pub const ANKI_WRITER: &str = "anki";

/// 导入锚点的日志种类。
const IMPORT_ANCHOR: &str = "importAnchor";

/// Anki 来源日志的派生 HLC 文本（`physical:counter:writer`）；不是 Anki 来源 = None（排序键用操作自己的 HLC）。
///
/// - 导入锚点：`(at, 1, "anki")`（Dart `srsImportAnchorHlc(at)`）；
/// - 带 Anki revlog id 的日志：`(ankiId, 0, "anki")`（Dart `srsImportedRevlogHlc(ankiId)`）；
/// - 其余（Anki 来源却既不是锚点、也没有 revlog id）：None。导入器不写这种日志。
pub fn anki_source_hlc(origin: &str, kind: &str, anki_id: Option<i64>, at: i64) -> Option<String> {
    if origin != ANKI_WRITER {
        return None;
    }
    if kind == IMPORT_ANCHOR {
        return Some(format!("{at}:1:{ANKI_WRITER}"));
    }
    anki_id.map(|id| format!("{id}:0:{ANKI_WRITER}"))
}

/// 外来原生日志的标记键（日志 JSON 的顶层键，新代落在 `Log4.extra` 里）：Dart 回导 Fushi 导出包恢复的日志
/// （`srs_apkg_import.dart` `_remapExtLog`）带 `"foreignLog": true`。
pub const FOREIGN_LOG_KEY: &str = "foreignLog";

/// 日志的派生排序 HLC（新代投影与写回包的唯一入口，`store/gen4/cache.rs` `log_body`、`cmd/writes.rs` `logHlcs`）；
/// None = 用那条操作自己的 HLC。
///
/// - Anki 来源：[anki_source_hlc]；
/// - 外来原生日志（带 [FOREIGN_LOG_KEY] = true，第五波，交接 §38「第五波 导入与写接口」）：`{at}:0:fushi`。它是别的设备 /
///   别的 profile 写的复习，回导时作者 HLC 不进新代的操作（设计 §3.4），按导入那一刻的操作 HLC 排会让更早的复习排到本机
///   更晚的复习之后、改掉当前排程。发生时刻是来源数据，每台设备、每次导入算出来一样；计数器 0、写入者固定
///   [FOREIGN_WRITER]（不取 `origin` 原文：它是任意文本，带 `:` 就拼不成 HLC），同一毫秒的两条按日志 ID 定序。
///   **上界**：`at` 来自导入文件，不可信。真正回导的外来日志一定发生在载着它的那条操作之前，所以只有 `at <= op_wall`
///   （那条操作 HLC 的物理时刻，真相里的数据、每台设备读到的一样）才派生；`at` 晚于操作的不派生、回落到操作 HLC——否则
///   一条发生时刻在未来的伪造日志会排在此后本机所有复习之后，把排程钉死在它的结果上（第五波复核）。
pub fn derived_log_hlc(
    origin: &str,
    kind: &str,
    anki_id: Option<i64>,
    at: i64,
    extra: &str,
    op_wall: i64,
) -> Option<String> {
    if origin == ANKI_WRITER {
        return anki_source_hlc(origin, kind, anki_id, at);
    }
    (at <= op_wall && is_foreign_log(extra)).then(|| format!("{at}:0:{FOREIGN_WRITER}"))
}

/// 外来原生日志派生 HLC 的写入者。
pub const FOREIGN_WRITER: &str = "fushi";

/// [extra]（日志 JSON 里不认识的键，对象原文）带 [FOREIGN_LOG_KEY] = true。先按子串筛，绝大多数日志不必解析。
fn is_foreign_log(extra: &str) -> bool {
    extra.contains(FOREIGN_LOG_KEY)
        && serde_json::from_str::<serde_json::Value>(extra)
            .is_ok_and(|v| v.get(FOREIGN_LOG_KEY) == Some(&serde_json::Value::Bool(true)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// 与 Dart `test/anki_source_hlc_vectors_test.dart` 共用的向量。
    const VECTORS: &str = include_str!("anki_source_hlc_vectors.json");

    #[test]
    fn matches_the_shared_dart_vectors() {
        let root: Value = serde_json::from_str(VECTORS).unwrap();
        let vectors = root["vectors"].as_array().unwrap();
        assert!(vectors.len() >= 6);
        for v in vectors {
            let got = anki_source_hlc(
                v["origin"].as_str().unwrap(),
                v["kind"].as_str().unwrap(),
                v["ankiId"].as_i64(),
                v["at"].as_i64().unwrap(),
            );
            assert_eq!(got.as_deref(), v["hlc"].as_str(), "{v}");
        }
    }

    #[test]
    fn the_anchor_sorts_after_the_revlog_of_the_same_millisecond() {
        let revlog = anki_source_hlc("anki", "review", Some(1_700_000_000_000), 1_700_000_000_000);
        let anchor = anki_source_hlc("anki", "importAnchor", None, 1_700_000_000_000);
        let (r, a) = (revlog.unwrap(), anchor.unwrap());
        let parse = |s: &str| crate::history::parse_hlc(s).map(|(p, c, w)| (p, c, w.to_owned()));
        assert!(parse(&a).unwrap() > parse(&r).unwrap(), "{a} vs {r}");
    }

    /// 外来原生日志按标记派生 `{at}:0:fushi`（能被卡片历史解析）；没标记、标记不是 true、Anki 来源（照 [anki_source_hlc]）
    /// 都不走这条。
    #[test]
    fn a_marked_foreign_log_sorts_by_when_it_happened() {
        let at = 1_700_000_000_123;
        let marked = r#"{"foreignLog":true,"sc":{"x":1}}"#;
        let got = derived_log_hlc("fushi", "review", None, at, marked, at + 5).unwrap();
        assert_eq!(got, format!("{at}:0:fushi"));
        assert_eq!(
            crate::history::parse_hlc(&got).map(|(p, c, w)| (p, c, w.to_owned())),
            Ok((at, 0, FOREIGN_WRITER.to_owned()))
        );
        // 来源文本带 `:` 也拼得出合法 HLC（写入者固定）。
        assert_eq!(
            derived_log_hlc("od:d", "review", None, at, marked, at + 5).as_deref(),
            Some(got.as_str())
        );
        for extra in [
            "{}",
            r#"{"foreignLog":false}"#,
            r#"{"foreignLog":"true"}"#,
            r#"{"note":"foreignLog"}"#,
        ] {
            assert_eq!(
                derived_log_hlc("fushi", "review", None, at, extra, at + 5),
                None,
                "{extra}"
            );
        }
        assert_eq!(
            derived_log_hlc("anki", "review", Some(at), at + 5, marked, at + 5),
            anki_source_hlc("anki", "review", Some(at), at + 5)
        );
    }

    /// 发生时刻晚于载着它的操作的外来日志不派生（回落到操作 HLC）：`at` 来自导入文件，未来时刻不能把它排到此后本机的
    /// 复习之后。恰好等于操作时刻的照样派生。
    #[test]
    fn a_foreign_log_from_after_its_op_does_not_derive() {
        let at = 1_700_000_000_123;
        let marked = r#"{"foreignLog":true}"#;
        assert_eq!(
            derived_log_hlc("fushi", "review", None, at, marked, at - 1),
            None
        );
        assert_eq!(
            derived_log_hlc("fushi", "review", None, at, marked, at),
            Some(format!("{at}:0:fushi"))
        );
        // Anki 来源不受这条约束（另有 futureCards 守卫，派生规则照 [anki_source_hlc]）。
        assert_eq!(
            derived_log_hlc("anki", "review", Some(at), at, marked, at - 1),
            anki_source_hlc("anki", "review", Some(at), at)
        );
    }
}

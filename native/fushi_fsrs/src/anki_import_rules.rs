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
}

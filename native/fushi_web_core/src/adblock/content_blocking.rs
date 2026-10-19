//! 过滤列表 → WebKit 内容拦截规则（iOS / macOS WKWebView 不能逐请求拦截，只能交
//! `contentBlockers`）。导出、筛选与截断都在这里做完，Dart 侧只把每条规则原样映射成插件对象。

use adblock::lists::{FilterSet, ParseOptions};
use serde_json::{Map, Value};

/// 交给 `contentBlockers` 的规则条数上限。真实默认四份列表导出约 16.7 万条（2026-10 实测），
/// 超过 WKContentRuleList 的单表上限（iOS 15+ 15 万、更早 5 万），编译也慢；取 5 万保守值。
/// 截断时**只丢拦截规则、保留全部例外规则**（少拦，不误拦）。
pub const MAX_CONTENT_BLOCKERS: usize = 50_000;

/// 插件（flutter_inappwebview 的 `ContentBlockerTriggerResourceType`）认识的 resource-type。
const KNOWN_RESOURCE_TYPES: &[&str] = &[
    "document",
    "image",
    "style-sheet",
    "script",
    "font",
    "raw",
    "svg-document",
    "media",
];

/// 导出并筛选：
/// - 只留 `block` 与 `ignore-previous-rules`（cosmetic 隐藏五端统一走 UserScript，
///   `css-display-none` 进规则表只是重复占名额；`block-cookies` / `make-https` 不属于广告拦截）；
/// - `resource-type` 里插件不认识的值（`popup` 等）丢掉；**全部**不认识就整条丢弃——留个空数组
///   等于「匹配所有类型」，会把规则放大；
/// - `if-*` 与 `unless-*` 同时出现（WebKit 规定互斥）的整条丢弃；
/// - 超过 `max_rules` 时只截拦截规则（顺序：拦截在前、例外在后）。
pub fn export(texts: &[String], max_rules: usize) -> Result<Vec<Value>, String> {
    let mut set = FilterSet::new(true);
    for text in texts {
        set.add_filter_list(text.clone(), ParseOptions::default());
    }
    let (mut rules, _used) = set
        .into_content_blocking()
        .map_err(|_| "content blocking conversion failed".to_string())?;
    if !rules.is_empty() {
        // ABP 语义：顶层文档请求默认不拦；内容拦截格式表达不了，按上游建议追加这条例外。
        rules.push(adblock::content_blocking::ignore_previous_fp_documents());
    }
    let raw = serde_json::to_value(&rules).map_err(|e| e.to_string())?;
    let Value::Array(raw) = raw else {
        return Ok(Vec::new());
    };
    let mut blocks: Vec<Value> = Vec::new();
    let mut ignores: Vec<Value> = Vec::new();
    for rule in raw {
        match filter_rule(rule) {
            Some((true, r)) => ignores.push(r),
            Some((false, r)) => blocks.push(r),
            None => {}
        }
    }
    let kept_ignores = ignores.len().min(max_rules);
    let block_budget = max_rules - kept_ignores;
    blocks.truncate(block_budget);
    ignores.truncate(kept_ignores);
    blocks.extend(ignores);
    Ok(blocks)
}

/// 返回 `(是否例外规则, 筛选后的规则)`；不保留时 None。
fn filter_rule(rule: Value) -> Option<(bool, Value)> {
    let Value::Object(mut rule) = rule else {
        return None;
    };
    let is_ignore = match rule.get("action")?.get("type")?.as_str()? {
        "block" => false,
        "ignore-previous-rules" => true,
        _ => return None,
    };
    let Some(Value::Object(trigger)) = rule.get_mut("trigger") else {
        return None;
    };
    match trigger.get("url-filter") {
        Some(Value::String(s)) if !s.is_empty() => {}
        _ => return None,
    }
    if let Some(Value::Array(types)) = trigger.get("resource-type") {
        let raw_count = types.len();
        let kept: Vec<Value> = types
            .iter()
            .filter(|t| {
                t.as_str()
                    .is_some_and(|s| KNOWN_RESOURCE_TYPES.contains(&s))
            })
            .cloned()
            .collect();
        if raw_count > 0 && kept.is_empty() {
            return None;
        }
        trigger.insert("resource-type".into(), Value::Array(kept));
    }
    let non_empty = |t: &Map<String, Value>, k: &str| {
        t.get(k)
            .and_then(Value::as_array)
            .is_some_and(|a| !a.is_empty())
    };
    if (non_empty(trigger, "if-domain") && non_empty(trigger, "unless-domain"))
        || (non_empty(trigger, "if-top-url") && non_empty(trigger, "unless-top-url"))
    {
        return None;
    }
    Some((is_ignore, Value::Object(rule)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "||ads.example.com^\n||cdn.test/x.js$script\n@@||ads.example.com/ok/*\nexample.com##.ad\n||pop.test^$popup\n";

    #[test]
    fn keeps_block_and_ignore_drops_css_and_popup_only() {
        let rules = export(&[LIST.to_string()], MAX_CONTENT_BLOCKERS).unwrap();
        assert!(!rules.is_empty());
        for r in &rules {
            let t = r["action"]["type"].as_str().unwrap();
            assert!(t == "block" || t == "ignore-previous-rules", "{r}");
        }
        assert!(!rules
            .iter()
            .any(|r| r["trigger"]["url-filter"].as_str().unwrap().contains("pop")));
    }

    #[test]
    fn truncation_drops_blocks_first_keeps_exceptions() {
        let all = export(&[LIST.to_string()], MAX_CONTENT_BLOCKERS).unwrap();
        let ignores = all
            .iter()
            .filter(|r| r["action"]["type"] == "ignore-previous-rules")
            .count();
        assert!(ignores >= 1);
        let capped = export(&[LIST.to_string()], ignores).unwrap();
        assert_eq!(capped.len(), ignores);
        assert!(capped
            .iter()
            .all(|r| r["action"]["type"] == "ignore-previous-rules"));
    }
}

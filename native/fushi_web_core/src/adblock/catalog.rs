//! 内置过滤列表目录（官方地址）。
//!
//! - EasyList / EasyPrivacy：easylist.to 官方（GPL-3.0 / CC BY-SA 3.0 双许可，只下载使用、不随包分发）。
//! - AdGuard 中文 / 日文过滤器：AdGuard 官方 filters.adtidy.org 的 uBlock 语法变体
//!   （adblock-rust 兼容 uBO 语法）。filter id 224 = Chinese、7 = Japanese。
//!
//! `id` 是落盘文件名与订阅集里的稳定键（冻结，别改）。

/// 一份可订阅的过滤列表。
#[derive(Clone, Copy, Debug)]
pub struct CatalogList {
    pub id: &'static str,
    /// 展示名（列表官方名，不翻译）。
    pub title: &'static str,
    pub url: &'static str,
    /// 新安装时是否默认订阅。
    pub default_enabled: bool,
}

pub const CATALOG: &[CatalogList] = &[
    CatalogList {
        id: "easylist",
        title: "EasyList",
        url: "https://easylist.to/easylist/easylist.txt",
        default_enabled: true,
    },
    CatalogList {
        id: "easyprivacy",
        title: "EasyPrivacy",
        url: "https://easylist.to/easylist/easyprivacy.txt",
        default_enabled: true,
    },
    CatalogList {
        id: "adguard_chinese",
        title: "AdGuard Chinese",
        url: "https://filters.adtidy.org/extension/ublock/filters/224.txt",
        default_enabled: true,
    },
    CatalogList {
        id: "adguard_japanese",
        title: "AdGuard Japanese",
        url: "https://filters.adtidy.org/extension/ublock/filters/7.txt",
        default_enabled: true,
    },
];

pub fn find(id: &str) -> Option<&'static CatalogList> {
    CATALOG.iter().find(|l| l.id == id)
}

/// 默认订阅集（目录顺序）。
pub fn default_selection() -> Vec<String> {
    CATALOG
        .iter()
        .filter(|l| l.default_enabled)
        .map(|l| l.id.to_string())
        .collect()
}

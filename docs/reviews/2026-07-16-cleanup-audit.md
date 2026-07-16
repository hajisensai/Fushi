# 2026-07-16 重复代码整合 + 死代码删除审计（cleanup-wave1）

## 方法

- 多代理分区扫描（14 区，基线 `92a8796e6`）→ 每条发现由独立代理**反驳式验证**（基线快进到 `29bab5f1e` 后复核，574 提交漂移期间的失效发现被主动淘汰）→ 分波实施，每个实施代理动手前再对当前树复核。
- 发现总量 ~110 条；验证后死代码类 36 条存活、1 条反驳（v38 合集 API `getCollection*` 仅测试调用——为 Phase 3-4 UI 预留，**保留**）。重复类 51 条中本轮只实施「逐字/字节级且无守卫钉死」的子集，其余进后续路线图。

## 已落地（本分支 10 个提交）

| 提交 | 内容 | 净行数 |
|---|---|---|
| `eaaf37aa8` | 死文件 10 个（VideoPlayBar、孤儿模型、HibikiSearchHistory/BottomSheet、dialog_content）+ 批量标签对话框 chrome 共享 `BatchTagPickerDialogFrame` | ≈ -440 |
| `1567985c4` | sync：死 API `resolveReachableHibikiUrl` 删除；Dropbox/OneDrive PKCE 流程收敛到 `pkce_oauth.dart` 单一真相源（授权 URL 逐字节不变） | -11 / +44* |
| `f05f90bf4` | 时钟/日期格式化 17 处收敛到 `HibikiTimeFormat` 4 函数；统计两页字节级重复抽 `stat_shared.dart`；阅读器 3 个死包装方法 | ≈ -100 |
| `10046a06b` | hibiki_dictionary：StructuredContent 层级(546+1877 mapper)、pre-FFI 搜索链、AnkiService 死抽象；包内 dart_mappable/build_runner/flutter_html 依赖随死代码摘除 | ≈ -2600 |
| `9fbcccfc1` | 死原生词典渲染链 4 文件 + `PlaceholderSourcePage` + Base* 死模板成员 + `creatorActiveStream` 端到端死流（零订阅+零发射） | ≈ -1250 |
| `e005df51f` | creator：死契约 `onCreatorOpenAction`（基类+19 覆写）、`CreatorFieldValues` 死 API、死 mixin 文件。制卡活路径（mining.part.dart 直读 `autoAddBookNameToTags`）已验真不受影响 | -627 |
| `1a2033bb6` | 小件批：VN scripts 死 JS 方法 12 个、死组件/枚举/barrel 5 文件、平台死接口成员、pkg-core 死 DAO 9 个（表结构零改动） | ≈ -660 |
| `648887d9d` | 陈旧 dartdoc 站点 **3821 文件**（fork 前 "yuuna" 时代生成物）、根部 Isar 残留脚本、重复图标 ~1.6MB、12 行零引用依赖（google_fonts / dart_mappable / expandable 等） | ~-80 万行(生成物) |
| (第二梯队 a) | 零引用 i18n key **416 个**（含删代码后新死的 88+ 个），全程 `i18n_sync.dart` 工具移除 + slang 再生成 | json -7242 / 生成文件 -3 万 |
| (第二梯队 b) | 书架视频恒空死路径：`experimentalVideoEnabled` 硬 true 毕业开关 + 书架侧不可达视频卡/对话框 15 方法；书架拖入导入链（活）与合集混合删除防御（活）精准保留 | ≈ -609 |

\* PKCE 收敛净 +44 行：安全敏感代码从两份逐字副本变为一份，是取舍不是行数游戏。

## 实施中主动跳过的项（验证过程发现不可安全机械合并）

- **WebDAV↔HibikiClient ~180 行重复**：已实质分叉（WebDav 侧 upload-then-delete vs delete-then-upload、`_ensureResolved` 差异）。正解是横跨 6-7 后端的 `BookFolderCacheMixin`/trio-mixin 重设计，见路线图。
- **拖放 prefilled 导入三件套**：函数签名/字面量被 ≥3 个源码扫描回归守卫用作锚点，属「被守卫有意钉死的近重复」。
- **`_jsStringLiteral` 双份不一致**：两侧输出字节形式各被测试钉死（jsonEncode 双引号 vs 手写单引号）。已加互指注释；真统一需连测试一起改（统一到 jsonEncode 方向）。
- **HibikiDropdown**：同文件的 `GamepadMenuDropdown` 有 4 处生产引用，只能做部分类删除，留后续。
- **批量标签对话框深合并**：apply 落库/三态行已分叉（书架走 TODO-308 改版），只共享了仍逐字相同的 chrome。

## develop 基线既有问题（非本分支引入，未修）

- 全量 `flutter test` 基线红 6 个：`log_upload_workflow_injection_guard`、`global_lookup_no_audio_hint_guard`、`video_subtitle_source`(prewarm 计数)、`popup_empty_entry_card`(popup.js classList TypeError)、`popup_mine_audio_fresh_resolve_static`、`sync_settings_visibility`(sync.content 可见性闭包)。
- `hibiki_anki` analyze 1 warning（测试 helper 未用参数，基线即有）。
- `ios/Podfile.lock` 残留已删插件 pod 条目（下次 mac 端 pod install 自动刷新）。
- `hibiki_audio` 使用 `package:characters` 未在 pubspec 声明（Flutter SDK 传递依赖，现状 CI 绿）。

## 后续批次路线图（已发现未实施，按价值排序）

**重复整合（需 focused cycle，多为跨文件 mixin/组件抽取）**
1. sync：7 后端 `TtuProgress/TtuStatistics/TtuAudioBook` get+update 三件套（~250 行）+ book-folder cache 块（~150）+ SyncAssetStore 委托 6 份（~120）+ 流式下载循环（~70）+ backup import/merge 闭包（~45）→ 统一 mixin/基类默认实现。
2. sync：backend_config.part.dart 三个近似凭据表单 StatefulWidget（~220 行）。
3. video：`VideoControlItem` icon+label 映射三份（~190）、两套控制条拖拽编辑器（~150，高风险）、Episode/Chapter 面板同构（~120）、controller 内 4 份二分查找（~30）。
4. reader：chrome.part.dart 三个手搓上下文菜单壳（~100）、三个 `_reanchor*` 编排样板（~70）、分页/VN 两 shell 可上移 `_sharedJs` 的 JS 块（~70+55）、content styles 参数管道（~30）。
5. pages：reader 家族与 mixin 的 popup-session 逻辑重复（~130，高风险，арch-cleanup 遗留「弹窗编排统一」范畴）、dictionary_dialog_page 内部三重复（~110）。
6. audiobook：ReaderHibikiSource 45 组 settings getter/setter 样板（~110）、文本匹配脚手架三份（~55）、导入对话框脚手架（~90）、章节列表构建五份（~35）、ext→parser 分派四份（~45）。
7. utils：ReorderableColumn/Grid 拖拽机器重复（~100，高风险）、HibikiModalSheetFrame padding 样板全仓 67 处（~50）。
8. creator：21 个 field 文件 ~70% 单例样板 → 数据驱动注册表（~180）。

**遗留/死代码（需先补验证或迁移方案）**
- `VideoControlCustomization` 三档 placement 旧模型（~280 行，高风险，v1 迁移不经过它）。
- sync 旧版 `/api/pair` v1 端点（~80，需确认无旧客户端）+ SMB→WebDAV 一次性设置迁移（~34，持久化 key）。
- 有声书目录模式残留 `_audioDir/audioRoot`（字段背靠 DB 列，需迁移方案）。
- 本轮实施后新孤儿：`FrequencyField.getFrequency`、`{Frequency,PitchAccent}Field.extraValuesFromMineFields`、`DeleteDictionaryParams`/`UpdateDictionaryHistoryParams`、`kShelfVideoCardAspectRatio` 常量、`home_video_page` 原毕业开关裸 `ref.watch` 订阅（需确认视频 tab 不依赖该重建时序后可删）。
- docs/specs 历史文档中对已删符号的散文引用（非构建输入，随后续文档整理）。

**红线（勿动清单，验证代理逐条确认过）**
`ttu_*` 持久化 key 族 / `window.hoshiReader` / popup.css 三镜像 / BUG-060 三处码点镜像白名单 / 弹窗冻结 API 名单 / v38 合集 API（Phase 3-4 预留）/ Cupertino renderer（隐藏内部能力，非死代码）。

## 验证记录

- `flutter analyze`：hibiki + 5 packages 全绿（唯一 warning 为基线既有）。
- `flutter test`：主套件 11587 过 / 6 失败=基线既有集合；hibiki_core 25、hibiki_anki 170、hibiki_audio 48 全绿。
- 每条删除均有实施代理在当前树的全仓 grep 复核记录（含字符串形式/守卫测试/原生配置）。

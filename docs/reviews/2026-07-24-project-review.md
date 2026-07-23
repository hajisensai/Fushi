# 2026-07-24 项目整体架构审查：冗长热点与重复代码合并

基线：`origin/develop @ dbb1f6c60`。本轮两个目标：①梳理整体架构、标出冗长热点；②扫描「同一段代码存在多份」的簇并**优先合并**。机械扫描（归一化行 + 15 行滑动窗口哈希，全仓 Dart）+ 4 路语义排查（EPUB 生成 / 录音与 creator / 同步后端家族 / 弹窗·统计·anki·解析器）。

## 一、架构总览（代码量分布）

生产代码（非生成 Dart）约 **26.5 万行**；测试 **30.2 万行 / 1729 文件** + 集成测试 1.9 万行 / 80 文件——测试体量已超生产代码。

| 层 | 行数 | 文件数 | 说明 |
|---|---|---|---|
| `hibiki/lib/src/pages/` | 79.5k | 126 | 最重的一层；`implementations/` 下 89 个页面文件 |
| `hibiki/lib/src/media/` | 51.1k | 144 | audiobook 24 / video 72 / torrent 15 |
| `hibiki/lib/src/sync/` | 40.3k | 98 | 7 个 `*_sync_backend` + 备份/互联/服务器 |
| `hibiki/lib/src/utils/` | 27.5k | 92 | 含 `hibiki_material_components.dart` 2859 行 |
| `hibiki/lib/src/reader/` | 12.8k | 17 | JS/CSS 注入封装 |
| `hibiki/lib/src/models/` | 12.2k | 18 | `app_model.dart` 5514 行 |
| packages 五包 | ~32k | — | audio 8.0k / core 7.0k / anki 5.8k / dictionary 4.0k / inappwebview fork 6.3k |

### 冗长热点（单文件 Top）

| 文件 | 行数 | 评注 |
|---|---|---|
| `video_hibiki_page.dart` | 6485（+18 个 part 共 7153） | 已拆 part 仍在涨；主体里还嵌着弹窗 overlay 同步等可下沉逻辑（见 §三-5） |
| `hibiki_core/database.dart` | 5589 | schema v51 迁移链，结构性长，可接受 |
| `app_model.dart` | 5514 | god-object 倾向；初始化 + 词典搜索 + 导入 + 媒体管理同居一类，已有子系统委托但仍在涨 |
| `backup_service.dart` | 3875 | 备份 + 合并 + 资产打包多职责 |
| `home_video_page.dart` | 3494 | 与书架页共享的批量合集操作各持一份（§三-6） |
| `reader_pagination_scripts.dart` | 3283 | JS 字符串包装，结构性长 |
| `reader_hibiki_page.dart` | 3263（+8 part 共 9649） | part 化后主体可控 |
| `hibiki_sync_server.dart` / `sync_orchestrator.dart` | 2889 / 2635 | — |

结构性判断：拆 part 只是物理切分，**页面层（79.5k）与 sync（40.3k）的膨胀本质是「共享逻辑在页面间复制」**——本轮机械扫描证实了这一点（下节）。

## 二、本轮已合并的重复簇（4 项，全部测试绿）

| # | 簇 | 重复量 | 合并落点 | commit |
|---|---|---|---|---|
| 1 | `TextToEpub` ↔ `CuesToEpub`：整套 ZIP 打包器 + OCF/OPF/NCX/nav 生成器两份逐字复制（仅 uid 前缀漂移） | ~150 行 ×2 | `hibiki_audio/src/matching/epub_builder.dart`（`EpubBuilder.assemble`，uid 前缀参数化保持 `hibiki-` / `hibiki-text-` 不变）；顺带给 TextToEpub 补了行为单测（此前该导入路径**零覆盖**）、测试侧 ZIP 读取器抽 `test/helpers/epub_zip_reader.dart` | `e018cdeab` |
| 2 | SRT/ASS/VTT 三份解析器的 isolate 派发脚手架（`parseStringAsync` + `_parseStringIsolate` + 阈值判定） | ~45 行 ×3 | `hibiki_audio/src/parsers/cue_parse_dispatch.dart`（`CueParseDispatch.run`）；公开 API 原签名转发，调用方零改动 | `e7448502b` |
| 3 | `AudioExportField` ↔ `ImageExportField`：`getSearchTermWithFallback` + `setSearching` + 搜索状态字段逐字复制 | ~60 行 ×2 | `hibiki/src/creator/export_field_search.dart`（`ExportFieldSearch` mixin on `Field`） | `853a35ed7` |
| 4 | AnkiConnect ↔ AnkiDroid：`_renderMinedFields` 尾段（context 克隆 + payload 16 字段透传 + 打包）逐字复制——新增 payload 字段最易漏改一端 | ~50 行 ×2 | `BaseAnkiRepository.renderMediaPayload`（@protected）；两后端只保留真实差异（媒体引用准备方式） | `91d543089` |

验证：`flutter analyze` 0 issue；靶向测试 28（epub）+113（parsers）+49（creator）+192（anki 包）+146（anki app）全绿；全量 `flutter test` 见 PR 描述。

## 三、待合并 backlog（按 收益/风险 排序）

1. **Dropbox ↔ OneDrive OAuth 外壳**（`handleAuthCode`/`_exchangeCode`/`restoreAuth`/`refreshAuth`/`_authHeaders` 五块逐字复制 ~42 行；`_checkResponse` 与授权 URL 是真实协议分叉**不动**）。方案：`PkceBackendAuthMixin` + `persistToken` 钩子。⚠️ 两后端 OAuth **无单测**，重构前先补回归网。
2. **hibiki_client ↔ webdav 路径式四件套**（`findOrCreateRootFolder`/`listBooks`/`ensureBookFolder`/`listSyncFiles` ~45 行，都基于同一 `WebDavOps`）。方案：`WebDavPathBackendMixin` + `ensureReady()` 钩子（hibiki_client 的 `_ensureResolved()` 时机必须逐点保留）。
3. **删除确认弹窗三份**：`_DeleteScopeConfirmDialog`（sync/deletion_prompt）↔ `ReaderHistoryDeleteDialog`（reader_history/dialogs.part）↔ `stat_delete_confirm_dialog`，build 主体逐字同构 ~46 行。⚠️ `md3_design_system_static_test.dart:1308,1431` 硬编码断言类名，重构须同步改。
4. **音频预览播放器三份**：`base_audio_field.dart:203-324` ↔ `audio_recorder_page.dart:175-296` ↔ `play_audio_action.dart:66-96`（AudioSession 配置 + becomingNoisy + 时长/滑条三件套，~105 行）。已实际漂移：recorder 修了 `_durationNotifier` 可空 bug（HBK-AUDIT-107）与 slider `max=1.0` 兜底，base **两处都没拿到**——这是「复制导致修复不同步」的活例。先抽 `beginDuckingPlayback` 会话 helper（覆盖三份），widget 三件套再议。
5. **查词弹窗根 Overlay 同步**：`home_dictionary_page._syncPopupOverlay` ↔ `video_hibiki_page._syncPopupOverlay` 几乎逐字（两页已共享 `DictionaryPageMixin`，此方法漏在 mixin 外）；`_buildPopupOverlay` 有 BUG-861 hover 转发分叉，上提需抽钩子。
6. **批量合并合集编排**：`home_video_page:1037` ↔ `reader_history/books.part:662`（决策纯函数已抽 `batch_combine.dart`，残余 DB 编排 + TOCTOU 复查 ~50 行两份）。方案：`combineMergeCollections({db, onRefresh})`。
7. **Enhancement ↔ QuickAction 注册脚手架**（本地化 map + `getLocalisedLabel/Description` + `initialise` 幂等 ~37 行 ×2，未漂移）：抽 `CreatorRegistryEntry` 基类，纯机械但触面广。
8. **统计页书/视频行**（`reading_statistics_page:1180` ↔ `video_statistics_page:410`，~45 行）：抽 `buildStatMediaRow`，golden 可能需更新。
9. **测试夹具成套复制（体量最大）**：sync 测试家族共享 140 行 ×3 / 56 行 ×7 的 harness，audiobook 测试 113 行 ×5、67 行 ×4，integration_test reader 系列 79 行 ×5——是测试 30 万行的主要水分。建议按家族抽 `test/sync/helpers/`、`test/media/audiobook/helpers/` 共享 harness，一个家族一个 PR。

## 四、明确不合并（故意的复制）

- **Material ↔ Cupertino 设置渲染器**：故意的平台双渲染器；auto 五平台统一 MD3，Cupertino 是隐藏内部能力。注意其不会自动获得 Material 侧修复（如 BUG-042 physics），属已知滞后。
- **`flutter_inappwebview_windows` fork 内 `in_app_webview` ↔ `headless_in_app_webview`（~217 行）**：上游 fork 的固有结构，为保持与上游 diff 最小不动。
- **弹窗三镜像 / background.js 双镜像**（popup / 扩展 content.css）：构建约束的镜像，改一处必须同步三处（守卫见 `reference_popup_extension_3way_parity`），不是可抽公共模块的重复。
- **`DictionaryPopupLayer` ↔ `DictionaryPopupWebView` 回调字段**：wrapper 转发层固有；可选抽 `DictionaryPopupCallbacks` 参数对象但改动面大、收益低，暂缓。

## 五、结论

- 「好品味」视角：本轮 4 个合并全部是**把特殊情况参数化后消掉整段复制**（uid 前缀、媒体引用准备、平台守卫），公开 API 零破坏、调用方零改动。
- 复制的真实代价已在仓里发生：簇 4（音频播放器）两处漂移=一处修了 bug 另一处没有；簇 4（anki payload）新增字段要人肉记得改两端。backlog 1/4/5 三项同属此类，优先级最高。
- 页面层与 sync 层的「冗长」大头不是单文件长，而是**页面间横向复制**；后续新功能落地时应默认先找 mixin/基类落点再写页面私有方法。

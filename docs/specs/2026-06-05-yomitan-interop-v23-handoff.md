# Yomitan 互通四条线 — v23 基线重新应用交接清单

- 日期：2026-06-05
- 背景：四条线（texthooker / yomitan-api server / 浏览器扩展 webext / 桌面剪贴板查词）在**旧 v14 基线**的 `worktree-yomitan-compat` 分支上做完了（39 提交，726 测试绿、analyze 0、全部双审 + final 审 Ready）。但该基线落后 develop **515 提交**、schema **v14 vs 用户 DB v23**，直接 rebase 会在 app_model/i18n/settings/home_page 反复冲突十几次，不可行。改为**在 v23 基线重新应用**。

## 起点
- 分支 **`yomitan-interop-v23`**（基于 develop，schema=23，已含本文件 + 六份设计/计划文档）。从这里开始。
- 旧实现参考分支 **`worktree-yomitan-compat`**：`git show worktree-yomitan-compat -- <path>` 取任意旧文件原文。
- 背景记忆：`project_yomitan_interop`（四条线细节 + 坑）、`feedback_no_worktree_app_on_prod_db`（**绝不用旧 schema app 开生产 DB**，会 downgrade 破坏）、`feedback_worktree_cwd_discipline`。

## 设计/计划文档（已在本分支 docs/specs/）
| 线 | 设计 | 计划 |
|---|---|---|
| 线1 texthooker（WS 收文本→home tab 逐词查词挖词） | 2026-06-05-yomitan-interop-design.md | 2026-06-05-texthooker-ws-client-plan.md |
| 线2 yomitan-api server（19633 宽松兼容 termEntries/tokenize） | 同上 | 2026-06-05-yomitan-api-server-plan.md |
| 线3 浏览器扩展 webext（后端 /api/mine+record + tools/browser-extension） | 2026-06-05-webext-and-desktop-clipboard-design.md | 2026-06-05-webext-plan.md |
| 线4 桌面剪贴板查词（clipboard_watcher+hotkey+window_manager→overlay） | 同上 | 2026-06-05-desktop-clipboard-plan.md |

## 新增文件（v23 上不存在，从 worktree-yomitan-compat 取 + 适配 v23 API）
- `hibiki/lib/src/sync/`：yomitan_term_entries_adapter.dart, yomitan_tokenize_adapter.dart, yomitan_api_server.dart, yomitan_api_server_manager.dart, texthooker_message.dart, texthooker_service.dart, texthooker_ws_client.dart, texthooker_ws_client_host.dart, clipboard_dedupe.dart, desktop_lookup_service.dart
- `hibiki/lib/src/pages/implementations/`：texthooker_page.dart, desktop_lookup_overlay.dart
- `tools/browser-extension/`（整个目录：manifest/background/options/content/scan/bridge-shim/vendor）
- 对应 `hibiki/test/sync/`、`hibiki/test/pages/` 测试文件
> 注意：新文件依赖下面的「集成点」改动（如窄接口 HibikiRemoteMiningService/HistoryService）+ 调用的 v23 API（DictionaryPageMixin/appProvider/JapaneseLanguage.instance/DictionaryEntry/HibikiSyncServer 等），搬过来后必 `flutter analyze` 逐个适配 v23 变化。

## 集成点（对着 v23 真实结构重打——v23 的 app_model/settings_schema/home_page 已大变，别套 v14 假设）
1. `hibiki/pubspec.yaml`：加 web_socket_channel ^3.0.0 + clipboard_watcher ^0.3.0 + hotkey_manager ^0.2.3 + window_manager ^0.5.1（pub get 后 generated_plugin_registrant 6 文件一并提交）。
2. `hibiki/lib/main.dart`：binding 初始化后，桌面门控 `windowManager.ensureInitialized()` + `hotKeyManager.unregisterAll()`。
3. `preferences_repository.dart` + `app_model.dart`：偏好 texthooker_enabled/urls、yomitan_api_server_enabled/port/key、desktop_clipboard_enabled/always_on_top + 转发。
4. `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart`：加 `HibikiRemoteMiningService`（mineEntry）+ `HibikiRemoteHistoryService`（recordHistory）窄接口。
5. `app_model.dart`：`_AppModelRemoteLookupService` implements 两新接口（mineEntry 用 platformServices.createAnkiRepository headless；recordHistory 用 mediaHistoryRepo+dictRepo，**不调有 UI 副作用的 addToDictionaryHistory**）+ createRemoteMiningService/createRemoteHistoryService + 持有 YomitanApiServerManager（懒建）+ initialise 尾部 3 处自启（yomitan / texthooker host / desktop clipboard，均 unawaited+catchError，desktop 加 isDesktop 门控）。
6. `hibiki_sync_server.dart`：构造加 miningService/historyService + POST /api/mine + /api/lookup/dictionary 的 record 参数。
7. `sync_settings_schema.dart`：HibikiSyncServer 创建点注入 mining+history service。
8. `settings_schema.dart`：lookup 行为 section 加 3 开关（texthooker / yomitan_api_server / desktop_clipboard，desktop 用 visible:isDesktop），onChanged 启停对应 service。
9. `home_page.dart`：加 texthooker tab（注意 v23 可能已有视频 tab，**tab 索引/数量要对着 v23 现状重算**，别套 v14 的 kHomeTabCount=4）+ 顶层 build 桌面门控挂 DesktopLookupOverlay。
10. `hibiki/lib/pages.dart`：export texthooker_page + desktop_lookup_overlay。
11. i18n：经 `tool/i18n_sync.dart` 加 texthooker/texthooker_enabled(_hint)/yomitan_api_*/desktop_clipboard_enabled(_hint)/always_on_top key（17 语言）+ `dart run slang`。
12. `test/settings/settings_schema_coverage_test.dart`：3 个新开关登记 `kCoveredElsewhere`（key 用英文标题如 `lookup/Texthooker (receive text)`）。

## v23 适配必查的坑
- **守卫**：每加页面/开关跑 `test/settings/md3_design_system_static_test.dart`（禁裸 fontSize / 裸 BorderRadius，用 Theme.textTheme / HibikiCard）+ `settings_schema_coverage_test.dart`（开关登记）。
- **API 变化**：DictionaryPageMixin 签名、appProvider 名、JapaneseLanguage.instance、DictionaryEntry/DictionarySearchResult 字段、HibikiSyncServer 构造/路由——v23 可能都变了，逐个对真实代码。
- **导航**：v23 home_page 大概率已有视频 tab，texthooker tab 的位置/魔数要重算。
- **不动 DB schema**（已 v23，四条线不需要 schema 变更）。
- **真机验证前别用任何 schema<23 的构建开生产 DB**。

## 执行方式
建议 superpowers:subagent-driven-development，按四条线的 plan 逐 task（新文件搬入+适配 + 集成点重打 + TDD + 双审），全程在 yomitan-interop-v23 分支，频繁提交。完成后 final 审 + 真机验证（外部 yomitan-api 客户端 / Textractor 推文本 / Chrome 扩展 / 桌面热键剪贴板）。

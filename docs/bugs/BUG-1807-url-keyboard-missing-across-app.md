## BUG-1807 · 全仓 10 处 URL/host 输入框漏声明 keyboardType，与 BUG-1804 同族

- **报告**：2026-08-24（修 [BUG-1804](BUG-1804-mihon-store-url-fullwidth-rejected.md) 时顺手全仓扫描发现，非用户报告）
- **真实性**：✅ 真 bug（同一根因的扩散面，已抽样核实两处）。

### 根因

与 BUG-1804 完全同源：输入框语义是 URL / host / 地址，但没有声明
`keyboardType: TextInputType.url`。中文/日文输入法在普通文本键盘下把 `:` `/` `.`
转成全角，下游 `Uri.tryParse` 要么解析不出 authority（全角冒号/斜杠），要么产出
`host%EF%BC%8Ecom` 这样的垃圾 authority 通过校验（全角句点）。

三个共享输入组件的默认值都是 `TextInputType.text` 且不带任何提示，所以这类缺陷
**会持续复发**：

- `FushiTextField`（`utils/components/fushi_material_components.dart:457`）
- `AdaptiveSettingsTextField`（`settings/settings_shared.dart:1606`）
- `_CredentialFieldSpec`（`sync/sync_settings_schema/backend_config.part.dart:20`）
- `SettingsTextItem.keyboardType` 可空、fallback 到 text（`settings_schema_widgets.dart:285-286`）

### 命中清单（按用户实际手输概率排序）

| # | file:line | 用途 | 值的消费方 |
|---|---|---|---|
| 1 | `sync/jellyfin_settings_widget.dart:155` | Jellyfin 服务器地址，hint `http://192.168.1.10:8096` | `JellyfinApi.normalizeServerUrl` |
| 2 | `pages/implementations/media_sources_view.dart:1606` | WebDAV 集合 URL | `_submit()` 里 `Uri.tryParse` 取 host/port |
| 3 | `pages/implementations/media_sources_view.dart:1614` | FTP/SFTP 主机名（**旁边 port 框已声明 number**） | `_NetworkSourceResult.host` |
| 4 | `sync/sync_settings_schema/backend_config.part.dart:468` | 备份后端 FTP 主机 | `FtpSyncBackend.testConnection(host:)` |
| 5 | `sync/sync_settings_schema/backend_config.part.dart:541` | 备份后端 SFTP 主机 | `SftpSyncBackend.testConnection(host:)` |
| 6 | `pages/implementations/dictionary_settings_dialog_page.dart:342` | 词典音频来源 URL 模板 | `AudioSourcesDialog.isValidRemoteUrl` |
| 7 | `pages/implementations/anki_settings_page.dart:141` | AnkiConnect 主机（**旁边 port 框已声明 number**） | `vm.updateAnkiConnectHost` |
| 8 | `pages/implementations/manual_download_task_dialog.dart:234` | 手动任务磁力链 | `parseMagnetInfoHash` |
| 9 | `pages/implementations/anime_download_dialog.dart:1286` | 番剧下载粘贴磁力 | `pushGenericMagnet` |
| 10 | `pages/implementations/torrent_settings_section.dart:381` | 下载自定义代理 host:port | `normalizeUserProxyHostPort` |

**自相矛盾的两处证据**（说明这不是「本来就不需要」，是漏了）：
`backend_config.part.dart:260` 的 WebDAV URL 已声明 url 键盘，同一表单里 468/541 没有；
`torrent_settings_section.dart:433` 的 qBittorrent 地址已声明，相邻的 381 代理框没有，
而语义完全相同的系统更新代理（`settings_schema_system.dart:310`）也声明了。

**排除**（无 url 键盘但不构成缺陷）：本地 OCR 可执行文件路径、各类 API key/token、
搜索关键词框、书名/作者覆盖、AniDB client name、任务标题、KPI 数值展示。
另 `pages/implementations/websocket_dialog_page.dart:90` 虽命中，但全仓无实例化点
（疑似死代码），当前用户不可达，处置前先确认是否该整体删除。

### 修复

- **[x] ① 已修复** — 按备注要求做两层收口，**主防线在消费端**：

  **第一层：消费端归一化（真正的防线）。** 每个「把用户字符串变成地址」的函数
  自己折全角，粘贴 / 扫码 / 配置回填一并覆盖：

  | file | 改动 |
  |---|---|
  | `sync/jellyfin_video_client.dart:289` `normalizeServerUrl` | 入口 `raw.trim()` → `normalizeUrlInput`。该函数纯字符串拼接、不过 `Uri`，全角会**原样**进请求 |
  | `anki/anki_view_model.dart:358` `normalizeAnkiConnectHostInput` | 同上。它按 `:` `/` 逐字符拆 scheme/host/port，全角让每步判空，整串被当主机名存下 |
  | `utils/net/app_proxy.dart:60` `normalizeUserProxyHostPort` | 同上。全角让 scheme 剥不掉、host/port 分不开，整串判非法 |
  | `media/torrent/magnet_utils.dart:8` `parseMagnetInfoHash` | 同上。全角下连 `magnet:` 前缀都匹配不上 |
  | `dictionary_settings_dialog_page.dart:39` `isValidRemoteUrl` + `_commitRemoteUrl` | 校验与**落库**都归一化。只改校验会变成「加的时候没报错、播放时永远失败」 |
  | `sync_settings_schema/backend_config.part.dart` | WebDAV/FTP/SFTP 的 `_save` **与 `_runTest` 同口径**，否则出现「测试通过、保存后连不上」的错位 |
  | `media_sources_view.dart:1542/1563` | WebDAV url（同时是落库的 `remotePath`）与 FTP/SFTP host |

  **第二层：11 个输入框补 `keyboardType`**（让手输那一路从源头就是半角）：
  Jellyfin 服务器、WebDAV URL、FTP/SFTP 主机 ×2 组、AnkiConnect 主机、
  词典音频源、两处磁力链、下载代理、`websocket_dialog_page`。

  **第三层：源码扫描守卫** `fushi/test/tools/url_input_keyboard_guard_test.dart`
  兜住新增：扫 `fushi/lib` 全树，凡 `TextField` / `TextFormField` / `FushiTextField` /
  `AdaptiveSettingsTextField` / `_CredentialFieldSpec` 的实参命中 URL 语义
  （`https://`/`wss://`/`magnet:` 字面量、`_url`/`_host`/`_address` 词族、示例域名）
  却没声明 `keyboardType`，即报错并指出 `file:line`。
  判据刻意只看**声明是否存在**、不强制值必须是 `.url`：有的地址框合理地用别的类型，
  守卫要拦的是「压根没想过这件事」。
- **[x] ② 已加自动化测试** —
  - `fushi/test/utils/url_consumer_normalization_test.dart`（11 条）：逐个锁住上述
    5 个消费端函数。每组**成对**断言「全角输入与半角输入得到同一个结果」——
    只断言「全角不为 null」放得过「解析出一个不同的、错的地址」。
    同时反向锁住既有规则不因归一化松动（代理带路径仍被拒、音频源缺占位符仍被拒、
    非磁力链仍返回 null）。
  - `fushi/test/tools/url_input_keyboard_guard_test.dart`：上述守卫，含扫描面自证
    （扫到的文件数 / 输入框数低于阈值即失败，堵住「一个文件都没扫到却绿着」）。
  - **四条变异实测**：拿掉 Jellyfin 的 `keyboardType` → 守卫精确报出该行且只报一次；
    把 `.dart` 后缀改坏 → 自证条款报「扫到 0 个文件」而非静默通过；
    磁力链与 AnkiConnect 各自回退成 `raw.trim()` → 对应用例变红。
    四次还原后全部文件 sha256 与基线逐字节一致。
- **覆盖边界（不要读成「全仓 URL 都归一化了」）**：消费端归一化只做了本 bug 清单里的
  10 处 + BUG-1804 的 Mihon / Aidoku 两处。**其余「已声明 `keyboardType` 因而不在清单里」
  的输入框，其消费端并未逐个审计**（`video_import_dialog`、`custom_fonts_page`、
  `video_shader_dialog`、`interconnect`、`video_external_provider` 等）。
  那些路径手输已是半角，但**粘贴一段带全角的地址仍会中招**——概率低，不为零。
  守卫只管 UI 层声明，管不到消费端，所以这个缺口不会被自动发现。
  彻底收口需要把「解析用户输入的 URL」做成一个调用方无法绕过的原语并全仓改造，
  那是比本轮更大的一次重构，应单独立项。
- **发现的额外事实**：
  - 守卫首次运行就抓出一处**我自己漏掉的** —— 改了 Jellyfin 的消费端却忘了给输入框
    补 `keyboardType`。这正是守卫存在的意义。
  - 守卫初版有两个实现缺陷，已修：`TextField(` 是 `FushiTextField(` 的后缀导致同一处
    被数两遍（改为要求左边界非标识符字符）；`obscureText: true` 的 token 框因
    `suffixIcon` 里嵌了 `accessTokenUrl` 跳转按钮而误报（改为遮蔽输入直接排除）。
  - `pages/implementations/websocket_dialog_page.dart` 全仓**只有自身定义、零引用**，
    确认是死代码。本轮只给它补了 `keyboardType` 让守卫通过；**是否整体删除应单独决定**，
    不混进 URL 修复。
- **备注**：**不要只是逐个补 `keyboardType` 参数就收工。** 那是给症状打补丁：
  下一个加 URL 框的人照样会漏，清单会再长出来一轮。两层收口缺一不可：
  1. **消费端归一化**才是根本防线——键盘类型只影响用户手输，粘贴、扫码、同步回填
     一样能带进全角。参考 BUG-1804 的做法：在各自的 `Uri.tryParse` / 校验入口调
     `normalizeUrlInput()`（`utils/net/url_input_normalizer.dart`）。理想形态是把
     「解析用户输入的 URL」收成一个共享原语，让调用方无法绕过归一化，而不是
     11 个地方各写各的。
  2. **源码扫描守卫**兜住新增：凡 label/hint 命中 url/host/address 词族、或 hint 以
     `http` / `ws` / `ftp` / `magnet` 开头的输入框，必须显式声明 `keyboardType`。
     新守卫必须做变异实测（改坏必红、还原后逐字节一致）。

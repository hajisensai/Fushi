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

- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
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

## BUG-1084 · host 模式误藏云备份上传开关，互联从同步方式消失且无入口
- **报告**：2026-07-25（用户：「同步方式怎么少了 hibiki 互联，还少了上传视频、书籍、有声书之类的全没了」「用互联做备份后端这个按钮根本没有」「我用谷歌云盘等其他的后端也应该能用」）
- **真实性**：✅ 真 bug（三处叠加，均沿真实代码路径验证）
  1. `a147a28ca` 给云通道的上传书籍/有声书/视频、自动同步、立即同步、比较统一加了 `!_isHostingInterconnect` 门控（`sync_settings_schema.dart:167/221/234/253/288/296`）。该理由（"host 无出站"）只在互联还是互斥单选（backendType==hibikiServer）的旧模型下成立；互联解耦成独立开关（PR#223）+ 双通道（BUG-988，`sync_auto_trigger.dart:104` `enabledSyncChannelBackends`）后，host 设备的云通道（Google Drive/WebDAV/…）照常出站，门控变成错误特例——用户开了「本机作为服务器」，云盘上传开关整排消失。
  2. 解耦时 `_isBackendSelectable`（`backend_config.part.dart:293`）对 hibikiServer 返回 false，把互联从「同步方式」选择器摘掉；一次性迁移（`sync_repository.dart:345`）还把已选互联的用户强制改回 googleDrive。
  3. 唯一补偿入口「设为备份后端」按钮位于互联分类的「交给已配对设备」区，门控 `interconnectActive && !_isHostingInterconnect`（`sync_settings_schema.dart:471`）——host 设备上同样被藏，入口彻底死循环。
- **[x] ① 已修复** — 见本分支提交：
  - `_isBackendSelectable(hibikiServer)` → true，互联回到「同步方式」选择器；`_selectBackend` 选中互联时自动 `setInterconnectEnabled(true)`（否则连接配置区不显示、通道认证不过，是个死后端），并在选择器下方加指引行 `sync.interconnect_config_note`（复用既有 i18n key `interconnect_moved_note`，零 key 增删）。
  - 新谓词 `_cloudOutboundUnavailable` = `backendType == hibikiServer && _isHostingInterconnect`：自动同步/立即同步/比较/host 说明行改用它——只有「同步方式本身是互联且本机在做 host」这个真正无出站的组合才隐藏；云后端无论是否 host 一律可见（引擎侧 `resolveChannelSyncFlags` 本就按通道读开关，纯 UI 门控 bug）。
  - 三个云通道上传开关（书籍/有声书/视频；漫画走 EPUB 书籍管线，属「上传书籍」通道）改为 `backendType != hibikiServer` 门控：唯一死区是同步方式=互联（该通道按 BUG-988 读互联专属上传开关，在互联分类可配），不再看 host 身份。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_settings_visibility_test.dart`：
  - 「upload switches hide only when the sync method is the interconnect (BUG-1084)」：源码守卫，三个上传开关必须带 `!= SyncBackendType.hibikiServer` 且禁止出现 `_isHostingInterconnect`。
  - 「auto-sync gate keys off cloud-outbound availability (BUG-1084)」+「the action gates key off cloud-outbound availability (BUG-084 / BUG-1084)」：六处门控必须走 `_cloudOutboundUnavailable`，且谓词链同时咬住 backendType==hibikiServer、serverEnabled、interconnectEnabled 三条件（BUG-084 的 stale serverEnabled 防线保持）。
  - 「the backend picker lists the interconnect again (BUG-1084)」+「selecting the interconnect as sync method enables interconnect (BUG-1084)」：选择器必须列出互联、选中必须自动开互联总开关。
- **备注**：互联独立分类（连接配置/host 开关/互联专属上传开关）保持不变；「设为备份后端」按钮保留（与选择器共用 `applyBackupBackendChange`，语义一致）。

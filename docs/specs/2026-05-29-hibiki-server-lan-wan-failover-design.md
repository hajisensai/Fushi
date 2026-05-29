# Hibiki 服务器·内网优先外网兜底(可排序地址列表)— 设计

- 日期: 2026-05-29
- 状态: 已确认,待实现
- 关联审查: 关闭 `docs/reviews/2026-05-29-deep-quality-audit.md` 的 HBK-AUDIT-090(死代码 `FallbackSyncBackend`/`SyncBackendRegistry`)

## 1. 背景与问题

Hibiki 同步当前用**单选下拉**从 8 个后端里选一个(`sync_backend_type`),`resolveSyncBackend()` 一个 `switch` 返回单例。连接"另一台 Hibiki 服务器"走 `HibikiClientSyncBackend`(WebDAV 协议,url + token,username 固定 `hibiki`)。

痛点:`HibikiClientSyncBackend` 只能存**一个** URL(`sync_hibiki_client_url`)。用户在家用局域网地址连自己的 PC 服务器,**一出门 LAN 地址连不上,同步直接失败**——没有外网地址兜底。

仓库里有一段**死代码** `FallbackSyncBackend`(通用多后端失败转移)+ `SyncBackendRegistry` + `getFallbackOrder/setFallbackOrder`,带测试但从未在生产实例化,且有"逐操作切后端导致 folderId 串台"的潜在 bug(HBK-AUDIT-090)。

## 2. 目标 / 非目标

**目标**
- 一台 Hibiki 服务器配置**有序、可开关的 URL 列表**(LAN→WAN→…),用户可拖拽排序(对标词典列表)。
- 同步运行开头探测候选 URL,选**第一个可达**的,整次运行只用它(内网优先,外网兜底)。
- LAN 发现的设备地址**加入列表**,而非静默覆盖并清空 token。
- 删除死代码 `FallbackSyncBackend` / `SyncBackendRegistry` / `getFallbackOrder` / `setFallbackOrder`,关闭 HBK-AUDIT-090。

**非目标(明确推迟)**
- 跨独立存储(PC 服务器 ↔ Google Drive)的兜底与双向和解。
- 内容大文件(EPUB/音频)的特殊处理:维持现状,跟随本次会话选中的 URL。
- `SyncBackendType.hibikiServer` 枚举正名为 client。
- 服务端模式(server_mode)从设置页拆分。
- 凭据加密、输入校验、导入后退出提示等其余配置项。

## 3. 关键约束(来自代码事实)

- `findOrCreateRootFolder()` 把 baseUrl 烤进缓存路径(`${_ops.baseUrl}/ttu-reader-data/`),`_titleToFolderId` 同理。**因此整次运行选定一个 URL 后不能中途切换;若要换 URL 必须先 `clearCache()`。**
- 每次同步运行的初始化点是 `restoreAuth(repo)`(`sync_auto_trigger.dart` 的 `_runAutoSyncAll`/`_runAutoSync` 都先 `restoreAuth → isAuthenticated → SyncManager.sync`)。选路逻辑挂在这里,**不改 `sync_auto_trigger.dart` 与 `SyncManager`**。
- token 是单个 `sync_hibiki_client_token`(base64,备份时按 `sync_%token%` 被剥离);多个 URL **共享同一 token**(同一台服务器)。
- 偏好存在 Drift `preferences` 表;新增 URL 列表用 JSON 串存,**无需 schema 迁移**。

## 4. 数据模型

新增偏好键 `sync_hibiki_client_urls`:JSON 编码的有序数组,元素 `{ "url": String, "enabled": bool }`。下标即优先级。URL 非密钥,不被备份剥离。

`SyncRepository` 新增(放在 "Hibiki Client" 段):
```dart
static const _keyHibikiClientUrls = 'sync_hibiki_client_urls';

/// 有序候选地址。读不到新键时,从旧单键 [_keyHibikiClientUrl] 迁移种子。
Future<List<HibikiClientUrl>> getHibikiClientUrls() async { ... }
Future<void> setHibikiClientUrls(List<HibikiClientUrl> urls) async { ... }
```

新增小数据类(放 `hibiki_client_sync_backend.dart` 顶部或 `sync_repository.dart`):
```dart
class HibikiClientUrl {
  const HibikiClientUrl({required this.url, this.enabled = true});
  final String url;
  final bool enabled;
  Map<String, dynamic> toJson() => {'url': url, 'enabled': enabled};
  factory HibikiClientUrl.fromJson(Map<String, dynamic> j) =>
      HibikiClientUrl(url: j['url'] as String, enabled: j['enabled'] as bool? ?? true);
}
```

**向后兼容迁移**(在 `getHibikiClientUrls()` 内):新键缺失/为空时,读旧 `sync_hibiki_client_url`,非空则返回 `[HibikiClientUrl(url: legacy, enabled: true)]`。旧 `getHibikiClientUrl/setHibikiClientUrl` 保留(标 `@Deprecated`),生产调用点全部切到列表 API。

## 5. 选路生命周期(核心)

在 `HibikiClientSyncBackend` 内新增:
```dart
typedef HibikiProbe = Future<bool> Function(String url, String token);
// 默认实现:用短超时 WebDavOps.testConnection 探测;401/403 抛 SyncAuthError。

List<HibikiClientUrl> _candidates = const [];
String? _token;
bool _sessionResolved = false;
static const Duration probeTimeout = Duration(seconds: 2);
final HibikiProbe _probe; // 构造可注入,默认走真实探测,便于单测
```

- `restoreAuth(repo)`(每次运行开头,**保持廉价、不打网络**):
  - `_candidates = (await repo.getHibikiClientUrls()).where((u) => u.enabled)`;`_token = await repo.getHibikiClientToken()`;
  - 二者任一为空 → 返回 `false`;
  - 用 `_candidates.first.url` 临时建 `_ops`(令 `isAuthenticated == true`);`_sessionResolved = false`;返回 `true`。
- `authenticate(repo)`(设置页 sign-in):同样读列表,探测选第一个可达者建 `_ops` 并 `testConnection`;无可达则抛错。
- `_ensureResolved()`(在 `findOrCreateRootFolder()` 顶部惰性调用——它是每次同步的第一个网络操作):
  - `_sessionResolved` 为真 → 直接返回;
  - 否则按序 `_probe(url, _token!)`:
    - 成功 → 选中;
    - 超时/连接失败 → 跳下一个;
    - `SyncAuthError`(401/403) → 直接 rethrow(同服务器同 token,一处未授权即全错,不再轮询);
  - 选中 URL 若与当前 `_ops.baseUrl` 不同 → 重建 `_ops` + `clearCache()`;
  - 全部不可达 → 抛**可重试** `SyncBackendError`(本次运行失败,下次冷却后重探);
  - `_sessionResolved = true`。
- **中途不切**:解析后整次运行锁定该 URL。"出门正好卡在同步中" → 本次失败,下次/手动重试自动走 WAN。这是有意取舍(中途切要清缓存+重放操作,YAGNI)。

## 6. UI(对标词典可排序列表)

改 `sync_settings_schema.dart` 的 `_HibikiServerConfigWidget`:单 URL 输入框 → 地址列表。
- `ReorderableListView.builder` + `ReorderableDragStartListener` 拖拽手柄(参照 `dictionary_dialog_page.dart:857-887`);
- 每行:URL 文本 + 启用开关(`adaptiveSwitch`)+ 删除按钮;底部"添加地址"按钮 + 单个 token 字段;
- 拖拽/编辑/开关/增删 → `repo.setHibikiClientUrls(...)`;
- "测试连接":逐个探测,行尾标 ✓/✗;
- 可选小优化:私网地址(`192.168.`/`10.`/`172.16-31.`/`*.local`/`169.254.`)自动打"局域网"标,否则"外网"。

## 7. LAN 发现改为加入列表

`_LanDiscoveryWidget._connectToDevice`:不再 `setHibikiClientUrl(覆盖) + setHibikiClientToken(null)`,改为:
- `urls = await repo.getHibikiClientUrls()`;若不含 `device.webDavUrl` 则追加 `HibikiClientUrl(url: device.webDavUrl)` 并 `setHibikiClientUrls(urls)`;
- **保留现有 token**;设 `backendType = hibikiServer`;刷新。

修掉"点设备清空 token"的暗坑。

## 8. 错误处理

- 未配置(无 URL 或无 token)→ `SyncAuthError`(同今天);
- 全部不可达 → 可重试 `SyncBackendError`,经 `sync_error_messages.dart` 转可读文案;
- token 错(401/403)→ 快速失败,不轮询其余 URL。

## 9. 删除死代码(关闭 HBK-AUDIT-090)

删除:`fallback_sync_backend.dart`、`backend_registry.dart`、`test/sync/fallback_sync_backend_test.dart`、`test/sync/backend_registry_test.dart`;以及现已无用的 `SyncRepository.getFallbackOrder/setFallbackOrder`(本方案改用 per-server URL 列表,不需要通用 fallback)。`sync_fallback_order` 偏好键的历史数据行无害遗留。审查报告中 HBK-AUDIT-090 状态改为已解决。

> 先 grep 确认 `FallbackSyncBackend`/`SyncBackendRegistry`/`getFallbackOrder`/`setFallbackOrder` 在 `lib/` 下确无引用,再删。

## 10. 测试

- repo 往返:`setHibikiClientUrls`/`getHibikiClientUrls` 保序 + enabled 字段;
- 迁移:仅有旧 `sync_hibiki_client_url` 时,`getHibikiClientUrls` 返回单元素列表;
- 选路(注入假 `HibikiProbe`):
  - 第一个可达 → 选第一个;
  - 第一个超时、第二个可达 → 选第二个 + `clearCache` 被调用;
  - 第一个抛 `SyncAuthError` → 立即 rethrow,不探测后续;
  - 全部不可达 → 抛可重试 `SyncBackendError`;
  - `_sessionResolved` 缓存:解析一次后再调网络方法不重复探测;`restoreAuth` 重置该标志。
- widget:地址列表拖拽重排并持久化;LAN 点击设备 → 列表新增且 token 不被清空。

## 11. 涉及文件

- `hibiki/lib/src/sync/sync_repository.dart` — 新增 URL 列表 getter/setter + 迁移;删 `getFallbackOrder/setFallbackOrder`。
- `hibiki/lib/src/sync/hibiki_client_sync_backend.dart` — `HibikiClientUrl`、探测选路、`_ensureResolved`。
- `hibiki/lib/src/sync/sync_settings_schema.dart` — `_HibikiServerConfigWidget` 改可排序列表;`_LanDiscoveryWidget` 改加入列表。
- 删除 `hibiki/lib/src/sync/fallback_sync_backend.dart`、`hibiki/lib/src/sync/backend_registry.dart` 及对应测试。
- 新增/调整 `hibiki/test/sync/` 下测试。
- `docs/reviews/2026-05-29-deep-quality-audit.md` — HBK-AUDIT-090 标记已解决。

## 12. 验证

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
```
在 `hibiki/` 下运行。无 Android manifest/Gradle 改动,不需 `assembleRelease`。

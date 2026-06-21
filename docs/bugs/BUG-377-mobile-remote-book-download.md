## BUG-377 · 手机无法下载对端配对设备书籍(Android明文HTTP被network_security_config拦截)
- **报告**：2026-06-21（用户：TODO-668）
- **真实性**：✅ 真 bug（平台边界配置错误·确定性·非不可控网络环境）。根因 `hibiki/android/app/src/main/res/xml/network_security_config.xml:3`
- **[x] ① 已修复** — `network_security_config.xml`：放开 `base-config cleartextTrafficPermitted="true"`（允许局域网配对设备 + 用户自配明文 WebDAV/FTP 后端），并显式 `domain-config` 把日志上传域名 `logs.wrds.xyz` 钉死 https-only 防回归。提交 6948bb87a
- **[x] ② 已加自动化测试** — `hibiki/test/android/network_security_config_guard_test.dart`（源码扫描守卫：断言 cleartext 已放开 + 敏感公网域名仍禁明文 + manifest 引用了该 config）。提交 6948bb87a
- **备注**：

### 根因（沿真实代码路径验真）

手机点「配对设备」书卡下载 → `_downloadRemoteBook`（`reader_history/remote.part.dart:221`）→ `client.getRemoteBook(downloadId, dest)`（`hibiki_client_sync_backend.dart:650`）。下载前先 `_ensureResolved()`（`:149`）：从候选地址列表逐个 probe（`resolveReachableHibikiUrl` `:26`，probe = WebDAV PROPFIND `webdav_ops.dart:60`，2s 超时），选首个可达者再 `GET $apiBase/api/library/books/<title>`。

候选地址全是**明文 HTTP 到局域网 IP**：
- mDNS 发现的对端 URL = `http://$host:$port`（`lan_discovery_service.dart:22` 硬编码 http）
- 手动输入提示也是 `http://192.168.1.100:38765`（`interconnect.part.dart:148`）

但 `network_security_config.xml` 自引入起（commit `da5c4ffad`，2026-05-16）就是：
```xml
<base-config cleartextTrafficPermitted="false" />      <!-- 全局禁明文 -->
<domain-config cleartextTrafficPermitted="true">
    <domain>localhost</domain>
    <domain>127.0.0.1</domain>                          <!-- 只白名单回环 -->
</domain-config>
```
→ Android 平台层在 Dart `HttpClient` 连 `http://192.168.x.x` 时**立即抛 cleartext-not-permitted**（不耗 2s）→ probe 的 catch（`hibiki_client_sync_backend.dart:59`）把它吞成 `false` → 所有候选不可达 → `_ensureResolved` 抛 `SyncBackendError('No reachable Hibiki server address')` → 下载失败。

桌面端（Windows/macOS/Linux）无此平台门控 → **只有手机不能下载**，与现象完全吻合。配对设备下载在 Android 上**从未工作过**（自该 config 引入起）。

排除项：① 落地路径用 `getTemporaryDirectory()`（Android 应用私有目录，可写，无存储权限问题）；② host 服务端 GET `/api/library/books/<title>` 端点完整、绑 `0.0.0.0`、无平台门控（`hibiki_sync_server.dart:634`/`:146`）；③ mDNS 发现在 Android 可用（bonsoir 自带 multicast 权限）；④ 与 TODO-666（app 自动更新）不同子系统，但同属 cleartext 门控影响面。

### 修复

`network_security_config.xml` 改为允许明文（恢复 API≤27 默认行为），但保留对 app 自有敏感公网端点的明文禁止姿态：
- `base-config cleartextTrafficPermitted="true"`：放开局域网配对设备 + 用户自配明文 WebDAV/FTP（这些是用户主动配置的可信服务器，明文是设计内允许；host 文件头已声明 LAN 明文 HTTP + Basic auth 仅可信局域网可接受）。
- 不降级任何**现有** https 流量：云盘后端（Dropbox/OneDrive/Google Drive SDK）、日志上传（`logs.wrds.xyz`）本就 https，scheme 不变。
- 新增 `domain-config cleartextTrafficPermitted="false"` 显式钉死 `logs.wrds.xyz`（app 唯一硬编码公网端点）为 https-only，防止未来回归把它降级。

Android `network-security-config` 的 `<domain>` 不支持 CIDR 网段，无法只白名单 `192.168.0.0/16` 等私有段；放开 base + 钉死敏感域名是范围最小、消除特殊情况、不破坏既有 https 的方案。

### 验证

- `flutter analyze` 0；`flutter test test/android test/sync test/pages` 绿。
- 源码守卫 `network_security_config_guard_test.dart` 锁定配置不被回归。
- 需真机复现项：两台真机（一台 host 开同步服务器、一台手机当 client）同局域网，手机配对后点远端书卡下载，断言下载成功落库（无法在本机单测复现「真机明文连接」，平台拒绝发生在 Android native HttpEngine 层，单测/桌面跑不到）。

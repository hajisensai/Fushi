## BUG-3147 · 互联配置传输复用未重载的会话，重新配对后仍报「配对凭据被拒」
- **报告**：2026-10-07（GitHub issue #1997 问题一：Windows 当 host、Android 当 client，2.9.1；「从对端下载配置」报「对方设备已拒绝本机的配对凭据，请重新配对」，重新配对无效，做完一次词典同步后就好了）
- **真实性**：✅ 真 bug。「下载 / 上传配置」两个按钮直接拿单例 `InterconnectSyncBackend.instance` 打 host（`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:2129`），**不先 `restoreAuth`**；其余消费点（书架 / 视频页 / 首页 / 同步编排）都先 `restoreAuth(repo)` 再用单例。单例里的候选地址与 token 是进程里上一次 `_loadConfig` 留下的，重新配对只改库、不通知单例，于是旧 token 照旧被拿去打 `/api/interconnect/profile` → host 回 401 → `WebDavOps.checkStatus` 映射成 `SyncAuthFailureKind.pairingRejected` →「配对凭据被拒」。词典同步走 `runManualAssetTransfer`，那条路会 `restoreAuth`，顺手把单例重载成新配置——这才是「词典同步是配置同步的前置条件」的假象，两者之间没有任何数据依赖。
- **[x] ① 已修复** — `getRemoteProfileJson` / `putRemoteProfileJson` 改成必须带 `SyncRepository`，进来先 `_reloadSessionFrom(repo)`（= `restoreAuth`，自带配置签名判据，配置没变不重探），一台对端都没配对时如实抛 `pairingNotConfigured`（`fushi/lib/src/sync/interconnect_sync_backend.dart:990`）。参数必填，以后新调用点忘不掉。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_profile_session_reload_test.dart`：先按旧配对解析会话，库里换成新地址 + 新 token（模拟重新配对）后调下载 / 上传，断言会话落到新地址、探测只用新 token；未配对时报 `pairingNotConfigured`。
- **备注**：issue 建议的「检测到词典不匹配时提示」不需要——配置传输与词典没有依赖关系。

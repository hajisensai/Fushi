## BUG-620 · 扩展/远端查词弹窗无单词音频（server 只查本地库漏配置的远程源）
- **报告**：2026-07-08（用户：「查词弹窗还是不对，还是没有单词音频」，视频/沉浸制卡场景）。TODO-1335 ②。
- **真实性**：✅ 真 bug。
- **根因说明**：浏览器扩展/远端查词弹窗的单词音频链是 popup.js `resolveWordAudio` → bridge-shim
  `lookupAudio` 消息 → background `POST /api/lookup/audio` → server `_handleAudioLookup`
  （`hibiki/lib/src/sync/yomitan_api_server.dart:258`）→ `HibikiRemoteLookupService.lookupAudio`。
  其唯一实现 `_AppModelRemoteLookupService.lookupAudio`（`hibiki/lib/src/models/app_model.dart:4670`）
  **只查本地音频库**（`TtsChannel.instance.queryLocalAudio` + `extractLocalAudio`），完全忽略用户在
  「管理音频来源」里配置的**远程发音源**（jpod101/forvo 的 remoteAudio URL 模板、hibikiRemote LAN 源）。
  而 app 内查词弹窗走的是单一真相源 `resolveLookupAudioUrl`（`hibiki/lib/src/utils/misc/lookup_audio_playback.dart:38`）
  → `WordAudioResolver.resolveConfigured` 遍历**所有已启用源**。两条路径分叉：server 端音频解析退化成
  local-only。绝大多数日语学习者的单词发音来自远程源（很少建本地音频库）→ server 返回 `{url:null}` →
  扩展弹窗 ♪ 按钮存在（`/api/lookup` 的 `audioSources=enabledAudioSources` 非空使 popup 渲染按钮）但点了
  无声，即「有按钮没音频」。`HibikiSyncServer` 的 `/api/lookup/audio` 走同一 service，同病。
- **[x] ① 根因修复** — commit（本轮，见文末哈希）：
  - `_AppModelRemoteLookupService.lookupAudio` 改为复用 app 内同一条 `resolveLookupAudioUrl` 全源解析
    （本地库 + hibikiRemote + 远程 URL 模板），得到本地文件路径或远程 http(s) URL。
  - 新增纯 helper `hibiki/lib/src/sync/remote_audio_lookup_bytes.dart`：`remoteAudioLookupFromResolvedUrl`
    把解析结果归一成字节——远程 http(s) 走注入的 `downloadRemote`（`AppModel._downloadRemoteAudioBytes`
    复用 keep-alive http client 下字节），本地路径/`file://` 走 `loadLocalFile` 读文件；仍经本地 127.0.0.1
    短命 token 播放（扩展宿主在 https 页面无法直连任意远程 http URL——mixed content；127.0.0.1 是可信来源
    不受限）。content-type 优先取响应头 `audio/*`、缺失回退按扩展名。
  - 原 `_remoteAudioContentType`（local-only、扩展名表更窄）移进 helper 并补全常见音频扩展名。
- **[x] ② 自动化测试** — `hibiki/test/sync/remote_audio_lookup_bytes_test.dart`：
  `remoteAudioLookupFromResolvedUrl` 三分支（远程 URL→download、本地路径/`file://`→read、null/空→null）、
  content-type 推断（扩展名 + 响应头优先去参数 + 回退）、以及**回归守卫**（源码扫描 `lookupAudio` 确实经
  `resolveLookupAudioUrl` + `remoteAudioLookupFromResolvedUrl`，不再回退成只查本地库）。
- **备注**：TODO-1335。`flutter analyze` 净、`flutter test`（sync/mining/lookup/word_audio 相邻域）全绿。
  真机验收：在「管理音频来源」只启用一个**远程**发音源（如 jpod101/forvo 模板 URL，关掉本地库），在
  Netflix/YouTube 页用扩展查一个该源有发音的词 → 弹窗 ♪ 应能出声（此前静默）；再验本地库源仍照常。

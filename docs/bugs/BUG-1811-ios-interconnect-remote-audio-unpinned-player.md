## BUG-1811 · iOS互联远端音频绕过证书钉扎导致无法播放
- **报告**：2026-08-24（用户：iOS 实机）
- **真实性**：✅ 真 bug。真实配置为启用的 `fushiRemote` 音频来源 + 带证书指纹的
  HTTPS 互联 peer；查询 POST 本身在 `fushi/lib/src/sync/interconnect_post_transport.dart:85-104`
  正确使用钉扎 client，但 `fushi/lib/src/sync/fushi_remote_lookup_client.dart:145-161`
  只把 host 返回的自签名 HTTPS 短命 URL 原样交给上层。随后
  `fushi/lib/src/utils/misc/lookup_audio_playback.dart:126-143,179-189` 把该 URL 直接交给
  iOS WebView / 平台播放器；这两个消费者不知道互联保存的指纹，也不能复用刚才的钉扎
  client，于是 TLS 校验在真正取音频字节的第二跳失败。现有测试只断言「查询返回 URL」，
  没有发起第二跳 GET，故此前全部假绿。
- **[x] ① 已修复** — `InterconnectPostTransport.post()` 现在把实际命中的
  `FushiClientUrl` 随 JSON 结果返回；`getLookupAudioBytes()` 只允许同 origin 的
  `/api/lookup/audio/file`，继续使用该 peer 的同一证书指纹并设置 16 MiB 上限。
  `FushiRemoteLookupClient.lookupAudioUrl()` 对带指纹 HTTPS 响应不再泄露裸 URL，改为
  通过上述第二跳取字节、按内容 SHA-256 原子物化到应用私有 support 根缓存，再把本地 ref 交回既有
  WebView/native 播放链。明文 HTTP 旧 peer 保持原 URL 流播兼容。
  修复提交：`ab34944ea`。完成前审查继续发现两条同信任链缺口：带指纹 peer 返回
  `http:`/`file:`/`data:` 时旧码会原样交给播放器；物化缓存也没有生产淘汰。提交
  `a3e82e646` 后，带指纹候选只接受同源固定路径的 HTTPS 第二跳，其余 scheme 零 GET
  直接拒绝；缓存增加 7 天 TTL、64 MiB 总预算、按访问时间 LRU 淘汰和陈旧 staging 清理。
  完成前复审继续纠正两处根因：缓存不再落全机共享的 `systemTemp`，命中既有文件及并发
  rename 冲突时都重新核对 SHA-256，拒绝被替换/损坏的同名内容；第二跳 TLS、socket、
  HTTP client 和整段下载超时不再被 `catch (_) => null` 吞掉，而是转换为
  `RemoteLookupUnreachableError` 让既有 45 秒失败冷却生效。404/非 2xx/超限/空体仍表示
  peer 可达但无可用音频，并记录具体拒绝原因，不制造假冷却。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/fushi_remote_lookup_client_test.dart`：先以旧实现得到裸 HTTPS URL
    建立红测，再断言 POST/GET 两跳都调用完全相同的钉扎指纹，落地文件字节不变；相邻
    failover、明文 HTTP、可达性测试全绿。
  - `fushi/integration_test/interconnect_remote_audio_tls_ios_itest.dart`：iPhone SE
    （iOS 26.6）进程内起真实 `FushiSyncServer` 自签名 HTTPS host，真生成 M4A，经真实
    `FushiRemoteLookupClient` 完成两跳钉扎；断言本地文件逐字节相等、WebView 得到
    `data:audio/mp4`，并由 iOS 播放后端实际 `playAudioRef()` 成功。
  - 同一单测新增恶意 `http:`/`file:`/`data:` 三类返回（修复前第一例直接泄露裸 URL）
    与真实稀疏缓存文件 TTL/64 MiB 预算测试（修复前过期文件仍存在），均先红后绿。
  - 每个缓存用例注入自己由 `createTemp` 创建、结束递归删除的目录；预算只统计该用例目录，
    不再与其它 agent/worktree 共用 `/tmp/fushi_remote_lookup_audio`。新增第二跳 TLS 失败进入
    `RemoteLookupUnreachableError`、第二跳 404 保持普通 `null` 的成对回归。
### 合入 develop 前的两处收口（2026-08-25）

1. **超时量纲错配 —— 本 PR 唯一的行为回归**。上面 ① 里写的「整段下载超时……转换为
   `RemoteLookupUnreachableError` 让既有 45 秒失败冷却生效」在实现上把 RPC 往返预算
   （`FushiRemoteLookupClient` 默认 3s，`app_model` 走默认值）原样交给
   `getLookupAudioBytes`，而后者把 `.timeout(timeout)` 套在**整个流式下载**外面
   （`maxBytes` 默认 16 MiB）。结果是：一个活着但网慢的 peer 被判成「设备死了」，
   经 `InterconnectAssetUnreachableError → RemoteLookupUnreachableError →
   word_audio_resolver.dart` 的 `kRemoteAudioFailureCooldown` 关进 45 秒冷却——这个副作用在
   修复前不存在。
   **改法（根因）**：把两个阶段分开。`timeout` 只覆盖到拿到响应头（连接阶段，量的是
   「对端还活着吗」，超时仍算不可达）；整包字节下载走独立的 `transferTimeout`
   （`kInterconnectAssetTransferTimeout = 30s`），**传输超时返回 `null`（可达但慢 = 这次没音频），
   不转 Unreachable、不制造假冷却**。
2. **资产第二跳未禁重定向**。`_sameOrigin` + `uri.path == '/api/lookup/audio/file'` 白名单只作用于
   初始 URI，而 `http.Request` 默认 `followRedirects = true`（Dart 默认还跟随 https→http），一个 302
   即可把这个带凭据语义的 GET 引到任意主机。已改为 `..followRedirects = false`；3xx 落进既有
   「非 2xx = 没音频」分支。
3. **缓存 prune 挪出命中路径**。`_pruneRemoteAudioCache` 原本在 `output.exists()` 之前跑，缓存命中
   也要付一次「全目录 list + 逐文件 stat」。自动发音是热路径，prune 现在只发生在 miss/写路径上。

测试（均变异实测）：`fushi/test/sync/fushi_remote_lookup_client_test.dart` 新增
`a slow asset transfer is "no audio" (null), never a false unreachable cooldown`（去掉传输超时的独立
catch → 红）、`a connect-phase timeout on the asset hop is still unreachable`、
`the asset hop never follows redirects`（去掉 `followRedirects = false` → 红）。

- **备注**：`interconnect_remote_audio_tls_ios_itest.dart` 不在任何 runner 里（真单测门
  `flutter_test_failures.dart` 只跑 `test/`），只能真机/模拟器手跑。根因不是 iOS 音频解码或自动播放策略，而是同一个互联操作被拆成「已钉扎
  JSON POST」与「未钉扎媒体 GET」两条信任链。修复必须让第二跳继续绑定命中的 peer 与
  其指纹，并把取回的短音频物化为本地文件后再交给既有 WebView/native 播放路径；不得
  关闭 TLS 校验或给 WebView 全局放行自签名证书。修复后实机门通过。

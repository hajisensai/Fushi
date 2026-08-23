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
  通过上述第二跳取字节、按内容 SHA-256 原子物化到沙箱临时缓存，再把本地 ref 交回既有
  WebView/native 播放链。明文 HTTP 旧 peer 保持原 URL 流播兼容。
  修复提交：`ab34944ea`。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/fushi_remote_lookup_client_test.dart`：先以旧实现得到裸 HTTPS URL
    建立红测，再断言 POST/GET 两跳都调用完全相同的钉扎指纹，落地文件字节不变；相邻
    failover、明文 HTTP、可达性测试全绿。
  - `fushi/integration_test/interconnect_remote_audio_tls_ios_itest.dart`：iPhone SE
    （iOS 26.6）进程内起真实 `FushiSyncServer` 自签名 HTTPS host，真生成 M4A，经真实
    `FushiRemoteLookupClient` 完成两跳钉扎；断言本地文件逐字节相等、WebView 得到
    `data:audio/mp4`，并由 iOS 播放后端实际 `playAudioRef()` 成功。
- **备注**：根因不是 iOS 音频解码或自动播放策略，而是同一个互联操作被拆成「已钉扎
  JSON POST」与「未钉扎媒体 GET」两条信任链。修复必须让第二跳继续绑定命中的 peer 与
  其指纹，并把取回的短音频物化为本地文件后再交给既有 WebView/native 播放路径；不得
  关闭 TLS 校验或给 WebView 全局放行自签名证书。修复后实机门通过。

## BUG-1567 · 互联小型请求普遍缺超时且挂死请求占住远端清单缓存槽
- **报告**：2026-08-12（用户：互联健壮性审计）
- **真实性**：✅ 真 bug。根因两处：
  - `fushi/lib/src/sync/interconnect_sync_backend.dart`（修复前 `_listRemote` 只有
    videos/activity 传 `listTimeout`，其余全部小型端点——books/audiobooks/localaudio/
    dictionaries 清单、progress/position、aggregate、collections、tombstones、
    streamurl、service-config、cover、各 DELETE——`await req.close()` 与 body 读取
    均无超时；如修复前 `listRemoteDictionaries`→`_listRemote` 不传 timeout、
    `remoteBookProgress` / `remoteVideoStreamUrls` / `fetchRemoteCover` 裸 close+join）。
    host 接受 TCP 连接后停摆（休眠半死 / NAT 半开）→ future 永久悬挂 → 远端库页
    无限转圈。
  - `fushi/lib/src/sync/remote_library_cache.dart:84-92`（修复前）：`read()` 无条件
    复用 in-flight future——一条挂死的取数把该槽的所有后续读都拖进同一个死 future，
    永不自愈。
- **[x] ① 已修复** —（分支 `fix/interconnect-robustness-misc`，与 ② 同一提交）
  - `interconnect_sync_backend.dart`：新增实例级 `requestTimeout`（15s，沿旧
    listTimeout 量级；探测仍是 2s `probeTimeout`）+ `_sendBounded`（`req.close()`
    超时即 `req.abort()` 释放连接并抛 `TimeoutException`）+ `_readBodyBounded`
    （body 读取对称封顶）。全部小型端点统一改走两助手；`_listRemote` 去掉可选
    timeout 参数恒封顶。**豁免**（各有自己的超时/长传输语义）：下载走
    `ResumableDownloader` 的 firstByte/stall 停顿超时；流式上传 6 处（词典/书/
    本地音频/有声书/视频/字幕 PUT）body 时长与文件大小成正比、host 侧收尾
    （词典导入）可分钟级，固定值封顶会砍断合法慢传输。整体超时覆盖 connect 阶段，
    无需另调 WebDavOps.connectionTimeout。
  - `remote_library_cache.dart`：新增 `inFlightTtl`（60s，防御纵深）——超过信任期
    的在途请求视为挂死不再复用，直接发起新取数；死 future 迟到写回被 generation
    比对丢弃（原有机制）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_request_timeout_test.dart`
  （真 socket 停摆两形态 → TimeoutException 行为测试 + 「裸 `await req.close()` 只允许
  出现在 7 处流式白名单」源码枚举守卫）；`fushi/test/sync/remote_library_cache_test.dart`
  的「BUG-1567 in-flight TTL 自愈」组（fake clock：信任期内复用不变、超期自愈、
  迟到写回不污染）。守卫已变异实测（还原一处 `_sendBounded`→`req.close()` 计数守卫红；
  注释掉 in-flight TTL 判断自愈用例红）。
- **备注**：WebDAV 元数据三件套（PROPFIND/uploadJson/downloadJson，`webdav_ops.dart`
  层）只有 60s connectionTimeout、无响应超时，属同类但独立面（云备份通道共用），
  未纳入本轮爆炸半径；如需收口应在 WebDavOps 层统一做。

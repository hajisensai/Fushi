## BUG-2253 · Siglus已入队查词点击偶发未发布命中且终结原因缺失
- **报告**：2026-09-08（原版 Rewrite 体験版 Ver.2.00，Windows x86）
- **真实性**：点击已入队后没有发布命中的现象已复现；是否错误拒绝、具体终结原因仍待运行时证据。不能将它认定为 75% 缩放的确定性缺陷。
- **[ ] ① 未修复** — 本提交只补私有有界诊断，不改变正文身份、布局代际、epoch、未消费字形、窗口或 registry 拒绝规则。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/siglus_lookup_worker_test.cpp` 直接执行生产 consumer/publication，验证 20 个场景（含 12 类拒绝原因）、等待不产出终结记录、成功与重复、reset/覆盖范围、8 槽上限及 112 字节纯标量记录。x86/x64 `/O2 /W4 /WX` 均退出 0；这是诊断契约测试，不冒充已复现那次点击的确切根因。

### 已观察事实

- 原始游戏 PID 48540，实际 DLL SHA-256 `c38766f11e53dabb35d53a2489112108f5307b3d97a1a98b5017a7c2b0cfaffb`。只读本机元数据 `rewrite48540-lookup-private-metadata.json` 与 `rewrite48540-viewport-100pct.json` / `rewrite48540-viewport-75pct.json` 未含正文或游戏载荷。
- 75% 失败点击保留在队列事件 11：真实正文事件 1214、26 字、字符索引 11，几何代际 102、epoch 13065，客户区 960×540、投影矩形 `[428,420,22,23]`。它已被 worker 消费，但没有对应新 IPC hit。随后 100% 成功点击为队列事件 12。
- 75% 时直接以有界只读 RPM 执行生产 `ReadSnapshot`、owner `BuildSnapshot` 和 `RenderAllowed` 全部通过；profile/config/owner 设计尺寸仍 1280×720，实际 viewport/client 为 960×540，四项可见性阻止标志均为零。DLL 私有当前布局完整有效且持续收到字形。
- 同一正文事件与几何代际不变时，epoch 仍随分批重绘上升。此现象能解释候选拒绝路径，但没有记录证明队列事件 11 恰好因 epoch 被拒绝。之后同一句 75% 再点击已成功弹出词典，排除缩放后恒定失效。

### 诊断边界与下一门

`siglus_lookup_worker.inc` 的 `IsSiglusLookupPayloadEligible`、`TryPublishSiglusLookupPayload`、`ProcessSiglusLookupClickSubmissions` 仍沿原顺序检查和终结；新增记录只在终结后写入。布局重置及队列覆盖另记录其丢弃范围，不把被覆盖身份猜成当前正文。

私有符号 `g_siglus_lookup_worker_diagnostic_count` 和 `g_siglus_lookup_worker_diagnostics` 是 8 槽 seqlock 环，不扩展 IPC。每条 112 字节：序号、首/末队列号、预期/当前正文事件、预期/当前 geometry/epoch、字形和文本的已发布/已消费前沿、原因枚举与保留字。没有字符、路径、音频或指针字段。多条 reset/覆盖范围的未知事件身份为 0；单条 reset 仅在槽序号稳定时记录其实际身份。

下一门是在同一原始启动路径注入新 DLL，单击后只读该环，按原因枚举区分 layout/epoch、engine view、窗口/前台、投影、重复或发布函数拒绝（含 IPC / registry 检查），再决定是否需要根因修复。现有失败门保持，不以延迟、重试或放宽 epoch 制造命中。

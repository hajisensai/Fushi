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

### 后续首按边界（2026-09-08）

v7 实际会话 PID 72620（Hook SHA-256 `bc9238afee6d78864a835bdb3dc5f39e9fd1473ea7fda700adddcd106f9d0598`）终于取得明确 worker 拒绝：队列 1 的 event 61/current 61、generation 14/14、epoch 12/13 为 LayoutIncomplete；队列 2、3 对同事件在 epoch 16 成功发布；队列 4、5 的 event 226/current 226、generation 24/24 分别在 epoch 146/147、153/154 为 LayoutIncomplete。队列 1、4 的 glyph frontier/consumed 分别为 6347/6346、114861/114860（各差一个），队列 5 为 118472/118472；文本前沿均已消费完。私有证据在本机 rewrite72620-worker.json。此会话包含用户并行输入，不能把这些队列逐条归给主代理的指定坐标；但已证明真实释放入队后因 current layout 无效被拒绝，不再只是候选路径。后续游戏在原生 D3D9 device-lost 恢复循环中未响应，尚未完成受控复测。需审查 worker 对未发布 transport 尾项与分批重绘的失效区分，不能删除 epoch 或凭相同 generation 接受旧几何。

原始新会话 PID 6464 使用 DLL SHA-256 `e1e5616f5b4d248242a3a005eb604505089d2fd76e3797e246d9f12428b0fe4a`，首次点击直接推进而未显示词典。随后只读快照确认 `click_event_count=click_processed_seq=0`，不是仅凭 worker diagnostic count=0 推断未入队。第二次短句点击及之后长句点击已正常发布命中；因此不能认定准入一直失效。证据为本机 `rewrite6464-input-private-metadata.json`、`rewrite6464-input-admission-metadata.jsonl` 及主代理点击台账。历史 first-down 拒绝原因仍未知。

前置诊断由 `siglus_lookup_click_target.inc` 的真实 Read/Build 检查和 `siglus_lookup_click_policy.inc` 的真实采样/消息路径填写。它区分稳定目标失效、过期、身份/代际缺失、窗口/前台/客户区或投影失败、live view 返回失败、registry 准入返回失败、尚未同步，以及本次成功取得输入所有权。registry 内部拒绝未另作猜测拆分，也不会额外读取游戏内存。取得 down 所有权不等于 up 已入队或 worker 已发布。

新增私有 `g_siglus_lookup_press_diagnostics` 环为 8×160 字节固定标量，计数为 `g_siglus_lookup_press_diagnostic_count`，竞争丢弃计数为 `g_siglus_lookup_press_diagnostic_dropped`。在已准入调用面的 GetKeyState/GetKeyboardState 各自观测到 down 边沿、引擎 DOWN/DBLCLICK 消息，以及 lookup-owned up 未入队时记录；不记录每帧 hold、idle up 或成功 up，也不记录未进入这些调用面的输入。completion 保留 pending 与当次稳定目标的真实 event/thread/gen/epoch，沿原短路顺序诊断，没有额外游戏内存读取。两个采样面使用独立 TLS 观测状态；新 epoch 或观察到 capture=false 的早退会清诊断历史，既捕获重新启用后的首次 held，又不每帧重复；实际输入 sample state 不受诊断改动。写者只尝试私有 SRW 独占锁，冲突直接增加 dropped；锁内清槽 seq→写固定标量→发布 seq→最后发布 count。记录不含正文、资源路径或游戏对象指针。

`siglus_lookup_input_diagnostics_test.cpp` 直接包含生产 Read/Build/采样/消息函数，使用窄 Win32/view 边界与真实 registry，覆盖 22 种拒绝在 65 个调用面用例、9 个 owned-up 失败用例、half-transaction/hold、跨 capture/epoch/TLS 线程生命周期、不复活 miss、成功输入、原 view 读取次数、消息与采样分工、诊断锁冲突不改变接管、8 槽覆盖、真实 copy 边界 seq=0/count 未提前发布。并发测试通过 Windows ReadProcessMemory 读取本测试自己的环，验证 writer 暂停在 copy 中时被 reader 拒绝、发布后被接受，及有界多 writer/reader 交错中的记录一致性；不把普通 C++ 非原子数据并发复制当合法读协议。x86/x64 `/O2 /W4 /WX` 各 8 组通过，原 worker 各 20 场景保持通过。此补充仍只是诊断，不勾选根因修复。

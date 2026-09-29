## BUG-2768 · Siglus（CLANNAD）选项画面单击选项文字弹查词、选不了选项
- **报告**：2026-09-29（用户：W1ght；CLANNAD Steam 版 + 日语补丁，BUG-2712 修完后的回访）
- **真实性**：✅ 真 bug。BUG-2712 让选项画面的字形成为活动行（`native/galgame_hook/hook/adapters/siglus_lookup_worker.inc`
  的选项模式），点击目标随之在选项行上发布（`siglus_lookup.inc` 的 `PublishSiglusLookupClickTarget`）。
  三条单击路径——十参数家族的 GetKeyState 采样器（`siglus_lookup_click_policy.inc` `FilterSiglusLookupLeftButtonSample`）、
  引擎 WM 汇点（同文件 `ConsumeSiglusLookupInputMessage`）和八参数家族的消息事务
  （`siglus_lookup_message_transaction.inc`）——对任何已发布目标都一视同仁地「命中即吞点击并查词」，
  而点选项文字正是玩家选择选项的方式：点击被当成查词吞掉，游戏收不到，选项永远选不上。
  BUG-2712 备注里把它记成了「已知限制」（点行外空白或用键盘），用户实际无法接受。
  - **修复前对照（真机）**：同一存档、修复前 DLL（与上游 develop 点击代码一致），鼠标点「助ける」的「助」→
    probe `hits` 1→2、命中行「助ける」，游戏停在选项画面。
- **[x] ① 已修复** — 点击目标新增 `claims_clicks`（`siglus_lookup_worker_types.inc`）：台词行发布为 1，
  选项行发布为 0（`SiglusLookupLineClaimsClicks()`，`siglus_lookup_worker.inc`）。三条单击路径改用
  `ReadSiglusLookupClickClaimTarget`（`siglus_lookup_click_target.inc`），遇到选项行按新诊断原因
  `kTargetLeavesClicks` 拒绝，点击原样交给引擎去选；Shift 与悬停仍读同一目标，选项上照常查词、画框。提交：见 PR。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/siglus_lookup_worker_test.cpp`（选项模式不认领点击、
  台词重绘/新台词恢复认领）、`tests/siglus_lookup_message_transaction_test.cpp`
  `TestSampledFamilySubFrameTap`（`claims_clicks=0` 时 WM 与采样两条路径都不吞、不提交）、
  `tests/adapter_structure_test.py` `test_siglus_choice_click_is_left_to_the_engine`（三条单击路径必须走认领读取器、
  Shift 用普通读取器、发布处按选项模式置位）。x86 ctest 118/118、x64 ctest 114/114、结构守卫 57/57。
- **真机验证**（2026-09-29，本机 CLANNAD Steam `SiglusEngine_Steam.exe` SHA-256 `116A1B6A…DEA2D`，x86；
  本分支 `build-x86` 的 `fushi_voice_injector.exe --launch … --hold` 拉起、仅本分支 hook DLL 在进程内
  （SHA-256 `5386A56B…A624`）；宿主准入用只写 `lookup_enabled` 与 NativeOnly+NativeInputAllowed 的小工具模拟，
  `fushi_voice_lookup_probe --no-enable` 观察；读档 No.063 停在「こいつら、しつこいんだ」）：
  - 选项画面光标停「助」按 Shift → `hits` 1→2、命中行「助ける」（选项查词保留）。
  - 鼠标点「助」→ 游戏进入「てめぇら、うるせぇぞ」（选中「助ける」），`hits` 不变。
  - 「返回上一个选项」后触摸点「腕」→ 进入「ぶんっ、その腕を思いきり振りほどく。」，`hits` 不变。
  - 回归：台词上鼠标点字仍查词（`hits` +1，字序号正确）且 `text_writes` 不变（不推进）。
  - 真 Fushi 宿主（本分支 Debug 构建 + `gal_realgame_driver_itest.dart` 附着，`attached=activeNative`）：悬停框在「助」上时
    鼠标点「助」→ 进入「てめぇら、うるせぇぞ」且不弹查词卡；触摸点「腕」→ 进入「ぶんっ、その腕を…」且不弹卡。
  - 为读档临时备份 `savedata_zh/`，测后逐文件还原（哈希比对差异 0）。
- **备注**：选项上查词请用 Shift（或悬停后按 Shift）；单击/触摸点选项 = 选择。

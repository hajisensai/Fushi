## BUG-2336 · Windows宿主将快照读取冲突误报为没有原生查词provider
- **报告**：2026-09-07（Siglus Windows 适配静态契约审查）。
- **真实性**：✅ 真 bug。修复前 `LookupGeometryStatus()` 在共享映射检查成功后将 `error` 设为 `kNone`；连续四次身份/代际重读不一致时直接返回默认输出，形成 `ok()==true`、provider kind/id/status 全为零的伪快照。基线 `a4cefcce01` 的 `fushi/windows/runner/voice_hook_reader.cpp:2358`、`:2417` 与 `voice_hook_reader.h:304` 可见该路径。`flutter_window.cpp:1596` 据 `ok()` 标为 available，`attached_text_surface_window.cpp:2488` 覆盖旧 Ready；Dart `gal_attached_text_controller.dart:1042` 采纳该事件并在 `:1125` 重新评估，可能降为 needsCalibration 并撤销原生输入。这是把“本次没有采到快照”误当“已确认没有 provider”的契约错误。
- **[x] ① 已修复** — 宿主新增 `kGeometrySnapshotConflicted`，独立报告有界读取耗尽；身份采样仍最多四次、不等待写线程，诊断位不再参与 provider 身份一致性判断。pump 不发布该伪状态，attached metadata 只忽略明确冲突；有效 None/Unavailable、映射错误和新 epoch 仍替换或清除旧状态。见 `fushi/windows/runner/lookup_geometry_snapshot.h:28`、`voice_hook_reader.cpp:834` / `:2386`、`flutter_window.cpp:1597`、`attached_text_surface_window.cpp:2492`。仅修改 Windows 宿主，不修改 native DLL/共享 IPC/Dart 协议。修复提交 `aeedaedda6`，完整 Windows Release 构建退出 0。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/attached_shield_status_policy_test.cpp:237` 以可控读回调模拟每次身份/状态/文本代际/几何代际均变化，验证八次读取后明确失败且不产生 None；验证真实 None 立即替换 Ready、之后 Ready 可恢复。`:275` 的生产接线守卫覆盖读取错误、geometry 回调、仅冲突忽略及 epoch 清空。MSVC x64、C++17、`/W4 /WX /utf-8` 编译及运行通过，`EXIT_CODE=0`。
- **备注**：2026-09-07 14:09 的 SPRB popup 自动消失仅是此次审查线索；当时没有原始 provider 快照或读冲突计数证据，且后续工具报告用户输入，不能把该事件归因于本缺口，也不能据此声称本修复已解决该次运行时现象。真实 provider 退出仍必须生效，已显示 popup 不得靠忽略所有零值或会话错误强行保留。完整宿主构建由 integration owner 统一执行。

验证命令与本机证据（不入库游戏素材）：

```powershell
# 以下 run.cmd 实际调用 vcvarsall.bat x64，再以 /std:c++17 /EHsc /W4
# /WX /utf-8 与 FUSHI_RUNNER_SOURCE_DIR 编译该测试，随后运行生成的 exe。
& 'D:\codehibiki\.codex-test\siglus-engine-adapter\snapshot-test\run.cmd'
```

- 工作目录：`D:\codehibiki\.codex-test\siglus-engine-adapter\snapshot-test`。
- 实际脚本：同目录 `run.cmd`；测试产物：`geometry_snapshot_test.exe` / `.obj`。
- 编译与运行输出：同目录 `geometry-snapshot-test.log`，内容为测试源文件名及 `EXIT_CODE=0`；输出已从实际命令重定向保存。
- bug 工具：`dart run tool/bug.dart new geometry-snapshot-conflict-as-none ...` 自动分配 BUG-2336（扫描 93 个 ref、5 个工作区）；记录后执行 `dart run tool/bug.dart reindex` / `check`。
- 索引检查：`check` 退出码 0，本地不变式/索引通过；跨分支历史占号有 84 条警告，本次 BUG-2336 未撞号。完整输出在同一证据目录 `bug-check.log`；本次不改动无关历史编号。

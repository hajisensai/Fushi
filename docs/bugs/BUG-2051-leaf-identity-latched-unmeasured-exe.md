## BUG-2051 · 白2 一次瞬时的 exe 摘要测量失败被钉成永久身份拒绝，整场语音降级 Loopback
- **报告**：2026-09-02（用户：白色相簿好像有问题音频都降级了）
- **真实性**：✅ 真 bug，根因 `native/galgame_hook/hook/adapters/leaf_aquaplus_adapter.inc:436`（永久缓存读取）与同文件 `:660`（把测量失败与判定失败写成同一个 -1）
- **[x] ① 已修复** — `IsLeafAquaplusProfileMatched()` 只在**测量成功**时写 `g_leaf_aquaplus_profile_state`；`executable_read == false` 走有界重试（`kLeafIdentityMeasureBudget = 32`）并置 `kXAudioDiag2LeafExecutableUnmeasurable`，预算用尽才钉死。提交见文末。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py::test_leaf_identity_does_not_latch_an_unmeasured_executable`（源码扫描守卫，已做变异验证：删掉早返回块后该守卫报错）

### 现象

同一台机器、同一份 WA2.exe、同一条启动路径，有的会话原声正常，有的整场语音全部降级到系统
Loopback。降级会话的共享头是 `xaudio_diagnostics = 0x00000001`（只有 `kXAudioDiagQueueReady`，
`kXAudioDiagLeafLacHooksReady` 未置位）、`lookup_admission = EngineUnsupported`、
`lookup_executable_sha256` 为**空串**；正常会话是 `xaudio = 0x00200001`、`admission = 3`。

### 根因

`IsLeafAquaplusProfileMatched()` 用 `g_leaf_aquaplus_profile_state` 做**永久**三态缓存
（0 未知 / +1 匹配 / -1 拒绝），命中非 0 即直接返回，本会话不再重测。而函数末尾

```cpp
InterlockedExchange(&g_leaf_aquaplus_profile_state, profile != nullptr ? 1 : -1);
```

把两类完全不同的失败合并进了同一个 -1：

1. **量到了，但不是这个发行版**（`MatchesLeafAquaplusProfile` 为假）——确定结论，该永久钉死；
2. **压根没量到**（`executable_read == false`：`GetModuleFileNameW` 失败，或
   `Sha256FileForLeafAquaplus` 失败）——瞬时条件。

摘要要走 `BCryptOpenAlgorithmProvider` + `CreateFileMappingW`，而首次 `probe()` 可能落在注入
窗口内（loader lock、hook 安装中途）。一旦这一拍没量到，-1 就被永久写死：`probe()` 此后恒假 →
准入汇总里没有任何 adapter 认领 → 收敛成 `EngineUnsupported`、`install()` 里的
`TryHookLeafAquaplusResourceAudio()` 第一道门就返回 false，LAC 原声 hook 一次都装不上 →
整场语音只能走 Loopback。会话之间的差别就在这一拍，所以表现为"有时好有时坏"。

空 `lookup_executable_sha256` 是同一根因的直接印证：`PublishHostExecutableSha256()` 只在
`executable_read` 成立时调用，而 `EngineUnsupported` 分支正是从这个共享槽取摘要的。

### 排除项（都已实测证伪，不要重复走）

- **不是 exe 版本不符**：`005e71107ed70e662c41cb526879cdcf0b9486e067c0e5a306308688c17409ed`
  与 profile 钉定值逐字节相同（1220096 字节）。
- **不是二进制结构门**：离线逐项复跑 `IsLeafAquaplusProfileMatched()` 的结构校验——18 项 section
  角色、4 个唯一掩码模式（命中 RVA 与绝对操作数逐位相同）、embed 锚点、9 个 call return site
  ——**全部通过**。
- **不是锚点被别的 hook 改写**：实机 `ReadProcessMemory` 与磁盘字节逐一比对，基址 0x400000，
  6 个锚点全部一致。
- **不是 `TryHookSiglusOvk` / `LoadLeafVoiceArchives`**：新增诊断位显示这两道门在降级会话里
  一次都没被走到（它们在第一道门之后）。
- **`kDiagSiglusOvkHooksReady` 不能用来判断**：它只在 siglus 家族为真时置位，Leaf 复用同一套
  共享文件 hook 却永远不会点亮它，据此推断会得到相反结论。

### 附带

同批补齐了这条链的分型诊断位（`xaudio_diagnostics2`）：身份哈希匹配 / exe 不可测量 /
结构门拒绝 + 8 个分组位 / 资源音频三段门各一位。此前每道门失败都只是静默 `return false`，
真机上同形为"音频降级"，无法分型——这也是本 bug 定位耗时的直接原因。

- **备注**：修复后仍需在原始启动路径复测"当前文本 → 对应语音"E2E 才能改动
  `engine-support.yaml`；本条只修回归，不升级支持状态。

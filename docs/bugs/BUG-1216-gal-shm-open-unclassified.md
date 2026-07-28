## BUG-1216 · 共享内存打不开被压成一句「请重启 Hibiki」，真实原因（拒绝访问/版本不符/映射不存在）在 native 返回值处丢弃

- **报告**：2026-07-28（用户：另一台机器上 amanatsu 能捕获、AI6WIN 不能，失败侧只弹一句「捕获通道无法打开，请重启 Hibiki。」，无任何可排障信息）
- **真实性**：✅ 真 bug。根因 `hibiki/windows/runner/voice_hook_reader.cpp:177`（`VoiceHookReader::Open` 四条出口一律 `return VoiceHookStatus{}`）、`hibiki/windows/runner/flutter_window.cpp:1785`（`open` 失败一律回固定串 `voice hook shared memory not found`）、`hibiki/lib/src/mining/galgame_audio_source.dart:1038`（拿到 `error` 后**从不读取它**，直接落 `sharedMemoryUnavailable`）。BUG-1142 的备注已预告过这一条，当时未随修。

### 现象

同一台机器、同一个 Hibiki、同一份 helper：amanatsu 可以捕获，AI6WIN 不行，失败只有一句

> 捕获通道无法打开，请重启 Hibiki。

这句话对**三种处置完全相反**的现场长得一模一样，而且其中两种「重启 Hibiki」根本无效：

| 真实原因 | 用户该做什么 | 旧提示 |
|---|---|---|
| 目标进程完整性级别更高（游戏以管理员身份运行），映射 ACL 拒绝中完整性的 hibiki.exe | 以管理员身份运行 Hibiki | 重启 Hibiki（无效） |
| helper 与本体契约版本漂开（两架构 helper 只更新了一个时尤其像本例：32 位游戏能捕、64 位不能） | 更新/重装捕获组件 | 重启 Hibiki（永远无效） |
| helper 没建会话 / pid 不符 | 重开游戏、重试 | 重启 Hibiki（半对） |

因为提示不含任何事实，"一台能一台不能"这种最有信息量的对照现场也无法定位——用户和维护者都只能猜。

### 根因

原因在**三层各丢一次**，每层都把多值压成一个比特：

1. `voice_hook_reader.cpp` 的 `Open`：pid 非法、`OpenFileMappingW` 失败（`ERROR_FILE_NOT_FOUND` vs `ERROR_ACCESS_DENIED` 语义完全不同）、`MapViewOfFile` 失败、`ProtocolMatches` 五字段不符——四条出口全部 `return VoiceHookStatus{}`，`GetLastError()` 与双方版本号当场丢弃。
2. `flutter_window.cpp` 的 `open`：把上面的全零状态压成一句固定英文串。附带一个独立缺陷——失败判据是 `!s.hooked && !s.ok`，于是**「映射已建、hook DLL 还没置 hooked 位」这段正常启动窗口也被误报成「共享内存不存在」**，Dart 侧据此立刻降级回 loopback；引擎慢一拍的游戏因此永远拿不到引擎 PCM。
3. `galgame_audio_source.dart`：`opened['error'] != null` 只当布尔用，字符串内容从未被读。

三层都修才有意义：只修任意一层，原因仍在上游的 `return` 处丢掉。

### 修复

让每条出口在**返回类型上**就说明原因（同 BUG-1142 的思路）：

- native 新增 `VoiceHookOpenError`（`invalid_pid` / `mapping_not_found` / `access_denied` / `mapping_open_failed` / `map_view_failed` / `protocol_mismatch`）与 `VoiceHookOpenResult`（状态 + 原因 + `win32_error` + 纯事实 `detail`）；`Open` 改返回它，映射名与 `GetLastError()` 随失败带出，契约不符时列出**不一致字段的双方取值**（`shm=11/want 12` 这类）。
- channel `open` 失败回 `{error: <token>, detail: <事实>, win32: <码>}`；判据改成「`Open` 自己报了 error」，不再拿 `hooked` 位当映射是否存在的代理。
- Dart 新增 `galHookFailureFromVoiceHookOpenError`：`access_denied → accessDenied`、`protocol_mismatch → protocolMismatch`（新枚举值，不可重试），其余落 `sharedMemoryUnavailable`；native 事实经 `_captureFailure(nativeDetail:)` 追加到诊断**末行**。
- 文案层：**有原因时也附一手证据**。旧实现只在归类不出来时才附诊断，导致归类越准、用户拿到的事实越少。降级路径的证据经新增的 `GalHookSessionState.injectorDetail` 传到 UI（降级时 `GalHookLaunchResult` 是 `launched`，诊断挂不到它身上）。
- 新增 i18n key `game_hook_reason_protocol_mismatch`（经 `i18n_sync --add`，17 语言 + `dart run slang`）。

修好后同一现场会直接显示形如：

> 该游戏以更高权限运行，请以管理员身份运行 Hibiki（voice_hook open access_denied name=Local\HibikiVoiceHook_1234 win32=5）

- **[x] ① 已修复** — `hibiki/windows/runner/voice_hook_reader.h` / `voice_hook_reader.cpp`（`VoiceHookOpenError` / `VoiceHookOpenResult` / `VoiceHookOpenErrorToken` / `ProtocolMismatchDetail`）、`hibiki/windows/runner/flutter_window.cpp`（`open` 回 token + detail + win32，失败判据改用 `Open` 的 error）、`hibiki/lib/src/mining/galgame_audio_source.dart`（`protocolMismatch` 枚举、`galHookFailureFromVoiceHookOpenError`、`galHookOpenFailureDetail`、`galHookDiagnosticsDetail` 迁入、`_captureFailure(resolved/nativeDetail)`）、`hibiki/lib/src/mining/gal_hook_failure_text.dart`（`_annotate` 无条件附证据）、`hibiki/lib/src/mining/gal_hook_session_controller.dart`（`injectorDetail` 状态字段与三处写入）、三个 UI 调用点、17 语言 i18n。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_shm_open_error_test.dart` 15 例：token→原因逐条映射、`protocolMismatch` 不可重试、未知 token 不编造、每个归类都有可执行文案、detail 压行保留 win32/版本事实、**经真实 `open` 失败路径**（fake injector 宣告 hooked + mock channel 回各 token）断言原因与证据双双落进 `lastFailure`、injector 全绿时不得把确定原因猜回 unknown、归类得出时**也**要带证据、降级路径从状态取证据、无证据不生造括号；外加三条源码守卫：native 六个 token 齐全且 Dart 认得改处置的两个、`Open` 内不得再出现 `return VoiceHookStatus{}` 且必须读 `GetLastError`、channel 不得回退到固定英文串。

### 备注

- 本轮只改**读侧**（`hibiki/windows/runner/` + Dart），未碰 `native/galgame_hook/` 注入端，IPC 契约字段无变更（只是把已有 header 字段的比对结果说出来），不涉及 helper 重新发布。
- 用户现场在另一台机器，本机无法复现。本修复的交付物是**让下一次失败自己说清原因**：`access_denied` / `protocol_mismatch` / `mapping_not_found` 加上 win32 码与双方版本号，足以一次确诊 AI6WIN 侧到底卡在哪。真正的 AI6WIN 支持结论必须等拿到带 token 的新报错后再判，此前不得宣称该引擎已支持或已修好。

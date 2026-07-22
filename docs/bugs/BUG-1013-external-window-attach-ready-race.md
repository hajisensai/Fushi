## BUG-1013 · 外部窗口挖矿在helper就绪前打开共享内存导致降级
- **报告**：2026-07-22（用户：外部窗口挖矿绑定 manosaba 后显示 `engine_attach_failed`，无实时台词）
- **真实性**：✅ 真 bug。`hibiki/lib/src/mining/galgame_audio_source.dart:610-624` 的 attach 路径启动 helper 后曾直接调用 native `open`；只有 launch 路径等待 stdout 的 `OK hooked pid=<N>`。helper 尚未创建共享内存时，单次 `OpenFileMapping` 失败会立即终止有效 helper 并误降级到系统 Loopback。相同 helper 直接以 `--pid` 附加同一游戏可正常得到 `hooked=1`、`text_hooked=1`，排除了 native hook/游戏兼容性失败。
- **[x] ① 已修复** — `5be80971b`：launch/attach 统一等待 helper 的 `OK hooked` proof-of-life，并校验 attach 回报 PID 与所选窗口 PID 一致后才打开共享内存。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_audio_test.dart:505` 构造延迟输出 `OK hooked` 的 helper，断言就绪前 `open` 调用为 0、就绪后恰好打开一次并保留文本 hook 会话。
- **备注**：Windows Debug 真机复测已绑定正在运行的 manosaba（PID 64116）：状态由 `engine_attach_failed` 变为“运行中 · 游戏资源音频”，helper 常驻并收到 engine hook 文本事件；共享环探针为 `hooked=1`、`text_hooked=1`、`luna_active=1`。默认线程同时包含 `WideCharToMultiByte` 系统时间文本，需在现有线程选择器中筛选干净台词；这不是本条附加生命周期失败。

## BUG-3993 · 每次转录漏一个不退出的后台 isolate（「GPU 转录后显存常驻」未复现）
- **报告**：2026-11-02（用户排查内存：私有内存稳定在 7.0–7.3 GB，不持续上涨；怀疑用过一次 GPU 转录后进程显存一直挂着约 4.4 GB，另有大量 1–64 MB 的锁页内存块，推测原因是 CUDA 插件 EP 只注册不注销、共享显存池挂在全局 `OrtEnv` 上）
- **真实性**：
  - ✅ **isolate 泄漏是真的**。上游 `fushi_asr_core` 的 `asr_transcribe_isolate.dart` 里，`_isolateMain` 收尾时只关自己的端口，等 isolate 自然退出。但宿主 bootstrap（`fushi/lib/src/asr_host/asr_host.dart:63`）挂的 `BackgroundIsolateBinaryMessenger` 持有一个没有公开关闭方法的端口，isolate 因此永远不退，每转录一次漏一个。生产路径上实测：两轮转录的 isolate 都没有退出（`exited=false`）。
  - ❌ **「显存常驻 4.4 GB」未复现，根因假设被实测否定**。RTX 4070 Ti，CUDA 插件 EP（cu13-ep0.3.0），reazonspeech-k2-v2 fp32，DXGI 本进程 `CurrentUsage`：注册后基线 172 MiB → 转录峰值约 1384 MiB → 会话关闭后 **352 MiB**，第二轮之后仍是 352 MiB，不叠加。10 分钟和 20 分钟素材（带 `materialMs`）结果一致；CUDA 路径不走静态桶，所以峰值本来就只有约 1.2 GB。共享分配器的显存在会话关闭时已经回落，剩下约 180 MiB 大概率是 CUDA 主上下文。试验构建「最后一个 CUDA 会话释放时注销插件库」之后，收尾值仍是 352 MiB，**没有可测量的收益，因此不提交**。用户看到的 4.4 GB 来源仍不明（可能是本进程的其它 GPU 使用，比如视频、WebView、OCR，或者是 Task Manager 的不同计数口径），需要用户现场的具体读数和场景才能继续查。
- **[x] ① 已修复（上游）** — `_isolateMain` 收尾改为 `Isolate.exit(events, _ExitedMessage)`（hajisensai/fushi-subtitles#28，提交 `83e1bd8`）。已合并（`8ecd2061`），本仓七处 pub 依赖 + `fushi_compute` Cargo rev + 补丁目录同提交升级。
- **[x] ② 已加自动化测试** —
  - 上游 `packages/asr_core/test/asr/asr_transcribe_isolate_exit_test.dart`：bootstrap 里留一个永不关闭的端口，断言 isolate 收尾后退出。修复前 20 秒超时红，修复后绿。
  - 本仓真机探针 `fushi/integration_test/asr_cuda_vram_release_itest.dart`：走生产路径（真 bootstrap + CUDA 插件 EP）连跑两轮转录，断言 isolate 退出、DXGI 本进程显存回到注册后的基线附近、两轮不叠加。修复前红（`isolate exited=false`），本地 path override 指向修复后的上游再跑，全绿。
- **备注**：探针要用 `ASR_MODEL_SEED` / `ASR_CUDA_RT_DIR` / `ASR_AUDIO`（可选 `ASR_MATERIAL_MS`），经 `tool/run_windows_itest.ps1` 跑。本仓已升到上游合并提交 `8ecd2061`，真机复跑全绿（两轮 isolate 退出，显存 172→峰值 1384→352 MiB）。

## BUG-2701 · 带 TLS 回调的加壳 exe 被早注入卡死（喫茶ステラ 汉化版 Enigma）
- **报告**：2026-09-26（用户：「柚子社的krkr引擎的游戏好像星空咖啡馆有问题」；要求按引擎级适配、不做单游戏特判）
- **真实性**：✅ 真 bug，已在原始启动路径复现。样本《喫茶ステラと死神の蝶》整合包内的汉化 exe（`星光咖啡馆与死神之蝶.exe`，x86，SHA-256 `7e6106bbfd82b0635ecbb2c9308cb3ddd5661d8fb89ee7f22e58e40f9764fc31`，Enigma Protector：`.enigma1/.enigma2/.newimp` 节，1 个 TLS 回调）。注入器 `--launch --hold`（Fushi 生产路径）：`[inject] kernel32 … target=00000000` → 远程 `LoadLibraryW` `wait=258 exit=0x103`（10 s 不返回）→ `readyTimeout` rc=2 → 游戏随即退出。同一 exe 直接启动正常；正常启动后 `--pid` 附着也正常（`target=77630000`、`OK hooked`、存活）。
  根因是生命周期而非引擎：`CREATE_SUSPENDED` 后直接 `CreateRemoteThread(LoadLibraryW)`（`native/galgame_hook/injector/injector_main.cpp` `InjectDll`），**注入线程成了进程初始化线程**（`kernel32 target=0` 在所有早注入里恒成立），exe 的 TLS 回调（壳代码最常放这里）跑在注入线程上。对照：同目录原版 `CafeStella.exe`、PARQUET、夏空カナタ 无 TLS 回调（夏空カナタ 有 TLS 目录但回调数组为空），早注入全部正常。
- **[x] ① 已修复** — 提交 `3ab4237b6aa`：`native/galgame_hook/include/loader_init_gate.h` 按 PE 结构解析 TLS 回调；`injector_main.cpp` `RunLoaderInitGate` 在入口点写 `EB FE`，恢复主线程让它自己跑完进程初始化并停在入口点，挂起、还原原字节后再注入（仍早于 exe 自身任何代码）。只在「挂起创建 + 由注入器恢复 + PE 声明了 TLS 回调」时启用；拿不到主线程句柄 / 读不到映像基址 / 超时都明确打日志并退回旧行为。判据与引擎、游戏名、哈希均无关。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/loader_init_gate_test.cpp`（CTest `fushi_loader_init_gate_test`：32/64 位、有/无/空 TLS 回调、回调数组落在只有虚拟尺寸的节、入口点为 0、截断与损坏输入、启用条件）；`tests/adapter_structure_test.py::test_launch_runs_loader_init_gate_before_injection`（门在注入之前、只按结构判据、超时路径也还原入口字节）。
- **备注**：
  - 修复后原始路径真机：`[loader-gate] exe declares 1 TLS callback(s)` → `parked at entry 0063B053 after 2109–4719 ms` → `kernel32 target=77630000` → `OK hooked` → LunaHook 连上 → 游戏存活；`EmbedKrkrZ` 线程出汉化正文「呜啊……好晃眼……」，`decdiag=0x031e0903`（与原版一致：语音流 hook 就绪并已抓到资源）。
  - 回归：CafeStella.exe / PARQUET.exe（DARKSiDERS Steam 模拟）/ 夏空カナタ.exe（KiriKiri2）不过门，行为不变，均 `OK hooked` 且存活。
  - 双架构构建 + CTest（x86 118/118、x64 114/114）通过；制卡 E2E 未跑，`engine-support.yaml` 状态不升级。
  - 存量按哈希的 `kKirikiriDelayedAttachProfiles`（Futamata，BUG-1469）不是同一机制（那是 V2Link 边界装 raw stream hook 时 AV），手头无样本，未收编；按新规则仍是待收编技术债。

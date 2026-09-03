## BUG-1708 · 自更新被自己造成的文件占用挡住且失败后 app 不回来
- **报告**：2026-08-18（用户：「fushi 自动更新好像没给我关闭 fushi 再打开，只关闭了」）
- **真实性**：✅ 真 bug，三层独立缺陷叠加，现场证据齐全。

### 用户现场（2026-08-18 抓到实时日志）

装的 `fushi.exe` 停在 `2.1.1+11666`（8/15 09:05 构建），8/16 起下载的
11709 / 11723 / 11758 / 11793 / 11809 **五次更新一次都没装上**。

- `updates\fushi-2.1.1-debug.11809-windows-setup.install.log`（01:00）：
  `PrepareToInstall failed: 检测到 galgame 捕获组件正被占用` → `Got EAbort` → 一个文件都没改。
  同一形态在 11793（00:27）完全重演。
- 占用者**不是游戏**：RestartManager 与模块枚举都指向 `Weixin.exe`（pid 44152，
  8/15 11:29 启动，连开三天），它的地址空间里映射着
  `D:\APP\Hibiki\voice_hook\x64\fushi_voice_hook.dll`。
- `update-handoff.json` 停在 `installerLaunchSucceeded: true` 之后再无进展，
  没有任何一环把 app 拉回来；`/SUPPRESSMSGBOXES` 把失败原因一起吞了。
- 微信关闭后重试（11810，12:12）安装真的开始了，却卡在
  `D:\APP\Hibiki\ffmpeg.exe`：`DeleteFile failed; code 5`，重试三次 → `Rolling back changes`。
  同样是「app 已退出 + 安装失败 + 无人恢复」。

顺带证伪一个猜测：Inno 的 `[Run] postinstall` 在 `/VERYSILENT` 下**照常执行**
（本机 Inno 6.7.1 最小样例实测 + 手动装 11810 的日志 `-- Run entry -- Filename: …\fushi.exe`
+ 进程实际起来三重印证）。成功路径本身没问题，不需要改。

### 根因（三层，各自独立）

1. **注入的 hook DLL 永远不卸载** — `fushi/lib/src/mining/galgame_audio_source.dart:1091`
   `EngineHookGalAudioSource.stop()` 只关共享内存通道 + `kill()` injector 进程；注入进宿主的
   `fushi_voice_hook.dll`（以及 LunaHost 注入的 `LunaHook<arch>.dll`）由宿主持有到宿主退出。
   宿主是常驻程序（微信）时，安装目录里那几个文件**永久不可替换**。
   *不采用「会话结束远程卸载 DLL」*：detour 还原失败会让用户正在玩的游戏当场崩溃，
   为装更新冒这个险不可接受。
2. **app 退出不回收自己的子进程** — Dart 的 `Process.start` 在 Windows 上不绑 job object，
   `exit(0)` 后 ffmpeg/ffprobe 继续活着并锁住 `<安装目录>\ffmpeg.exe`。
3. **安装失败后无人负责把 app 拉回来** — app 为让出文件锁主动退出，安装器只要没走到成功路径，
   `.iss` 的 `[Run]` 就不执行，Fushi 从桌面静默消失。`fushi/windows/runner/update_launcher.cpp`
   原本启动 Inno 后立即返回，谁都不为「app 还活着」负责。

- **[x] ① 已修复** — 四处改动：
  - `fushi/lib/src/mining/galgame_hook_runtime_stage.dart`（新增）+
    `gal_hook_session_controller.dart` 的 `defaultInjectorResolver` 改异步：注入运行时按内容
    分版暂存到 app 数据目录 `voice_hook_runtime/<sha>/<arch>/`，**从副本注入**，安装目录
    从此不被外部进程持有。刻意不回退安装目录（回退等于留着根因）。
    140 MB 的 `unity_audio_runtime/` 不搬，改由新参数 `--unity-runtime` 显式下发
    （`native/galgame_hook/injector/injector_main.cpp`）。
  - `fushi/lib/src/utils/misc/helper_process_registry.dart`（新增）+ `ffmpeg_backend.dart`：
    ffmpeg/ffprobe 统一登记；`platform_updater.dart` 在把安装交出去**之前**终止它们并
    **等到真正退出**（只发 kill 不等于文件已可替换）。
  - `fushi/windows/runner/update_launcher.cpp`：等安装器退出后检查单实例互斥体，
    没有 Fushi 活着就拉起同目录的 `fushi.exe`；CreateProcess 失败同样恢复。判据刻意不是
    Inno 退出码（语义随版本漂移，枚举它等于给每种失败加特例）。恢复结果写进 handoff marker。
  - `fushi/windows/installer/fushi.iss`：中止文案不再断言占用者是「正在玩的游戏」。
- **[x] ② 已加自动化测试** —
  - `fushi/test/mining/galgame_hook_runtime_stage_test.dart`（9 条，变异实测两处：
    改回 `<arch>-<version>` 目录名 → 2 红；内容分版退化成固定串 → 1 红；还原后 sha256 一致）
  - `fushi/test/utils/misc/helper_process_registry_test.dart`（4 条，钉住「等到真正退出」）
  - `fushi/test/build/update_launcher_relaunch_guard_test.dart`（6 条源码扫描守卫，
    变异实测：去掉启动失败时的恢复 → 1 红；还原后 sha256 一致）

### 验证

- `flutter analyze`（含 test）：No issues found。
- 定向：`test/mining/` + `test/lookup/` 1672 绿；`test/utils/misc/` + `test/build/` 1047 绿。
- native x86：完整 cmake 构建 + `ctest` 33/33 通过。
- native x64：`fushi_voice_injector` / `fushi_voice_hook` / 全部测试目标构建通过，
  `ctest` 32/33。**未通过项非本改动引入**：`fushi_utterance_window_test.exe` 构建产物
  在落盘后 2 秒内被本机第三方杀软删除（实测「构建后立刻 True → 2 秒后 False」，
  x86 同名产物完好；Defender 服务未运行，本机为第三方杀软）。该测试源码本次未改动，
  x86 下同一份代码通过。
- native x64 的 `fushi_unity_audio_runtime`（C# 目标）需 .NET 8 SDK，本机只有 6.0.428，
  故 x64 走 `msbuild /p:BuildProjectReferences=false` 逐目标构建；C# 提取器本次未改动。
- `native/galgame_hook` 结构门：`generate_engine_support.py --check`、
  `generate_luna_profiles.py --check`、`engine_support_manifest_test.py`、
  `galhook_workflow_test.py` 全通过；`adapter_structure_test.py` 有 1 个**预先存在**的红
  （主 checkout 基线同样失败，涉及 unity adapter，与本改动无关）。

- **备注**：用户机器已当场恢复到 `2.1.1-debug.11810`（关掉微信释放 DLL 后手动静默安装，
  安装器的 `[Run]` 自动拉起了新版）。修复本身对已装旧版用户的生效节奏：
  ①②④ 随新版落地即生效；③ 在 launcher 里，需先成功装上一次带新 launcher 的版本，
  再下一次更新失败时才由它兜底。

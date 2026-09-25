## BUG-2653 · CLANNAD Steam 版不被识别为 Siglus：语言后缀的 GameexeZH.dat + SceneZH.pck
- **报告**：2026-09-25（用户：「Clannad steam 版本下载了，你适配一下内嵌查词和音频」）
- **真实性**：✅ 真 bug — CLANNAD Steam 版（AppID 324160，`SiglusEngine_Steam.exe` 1.1.134.0，x86，
  SHA-256 `116A1B6AB5902BB6DC49E25086B1EF6F07D941DBB090B497FB7A158E997DEA2D`，无 Enigma 壳）按 Steam 语言
  下载带后缀的数据包：选简体中文时目录里只有 `GameexeZH.dat` + `SceneZH.pck`，没有无后缀的那一对。
  引擎身份判据三处都只认 `SiglusEngine.exe` 或 `Gameexe.dat + Scene.pck`：
  native `include/siglus_launch.h` `DirectoryLooksLikeSiglus`（注入器 `LooksLikeSiglusRuntime` /
  `DirectoryHasEngineSignature` 与 hook DLL `IsSiglusEngine` 共用），以及 Dart
  `fushi/lib/src/mining/galgame_audio_source.dart` `shouldUseLunaPcHooksForExecutable`。
  `IsSiglusEngine()` 为 false 时 Siglus adapter 的 `probe()` 不认领、`IsSiglusLookupProfileMatched()`
  直接拒绝（`siglus_lookup.inc` 的 `machine == I386 && IsSiglusEngine() && ResolveSiglusLiveFamily`），
  所以 OVK 语音、Siglus 文本和游戏内查词**整条链都不会启用**。
- **[x] ① 已修复** — 提交 `cf6017c73f4`
  - 目录签名改为「`Gameexe<后缀>.dat` 与 `Scene<后缀>.pck` 共享同一个后缀、成对出现」：后缀从目录里
    实际存在的 `Scene*.pck` 推出（空或 ≤8 个 ASCII 字母数字），不列语言清单。无后缀那一对照旧优先。
  - 新增 `include/siglus_launch_win32.h` 把磁盘枚举（`FindFirstFileExW("Scene*.pck")`，上限 16）与
    `DirectoryLooksLikeSiglusOnDisk` 收成一份，注入器两处与 hook DLL 一处共用，不再各写谓词。
  - Dart 新增 `directoryLooksLikeSiglus`，同一判据。
- **[x] ② 已加自动化测试** —
  - `native/galgame_hook/tests/siglus_launch_test.cpp`：语言后缀成对 → Siglus；后缀不一致 / 只有带后缀剧本 → 否；
    多语言并存时任一完整后缀对即认；后缀解析的大小写与非法字符。
  - `fushi/test/mining/galgame_audio_test.dart`：`SiglusEngine_Steam.exe` + `GameexeZH.dat` + `SceneZH.pck`
    启用 PC hooks；`GameexeEN.dat` + `SceneZH.pck` + `Scene_old.pck` 不启用。
- **备注**：
  - 离线候选证据：一次性探针把 `SiglusEngine_Steam.exe` 以映像装载、补 IAT 后逐族跑查词结构解析器，
    结果 `luna_scenario=1 native_ecx=0 legacy=0 eightarg=0 unique=1`——唯一命中 LunaScenario 族。
    这只是 `candidate`，不是运行期证据。
  - 真机原始路径未跑通：本机 `steam://run/324160` 被 Steam 转成「远程畅玩」（库里显示 CLANNAD 正在另一台
    电脑上运行），游戏未在本机启动，`process_found` 即未通过。`engine-support.yaml` 的 Siglus 条目未改
    （verified 引擎的声明受哈希白名单冻结，需 release 级台账才能动）。
  - 用户 Steam 语言设为简体中文，剧本是中文；学日语要把 CLANNAD 的 Steam 语言改为日语重新下载日文剧本。

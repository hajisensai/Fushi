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
- **顺带修复** — 提交 `4a2ee8e66a9`：注入器 `steam://run` 路径发现进程后 15ms 即注入，绕开了 Siglus
  既定的「主窗口就绪后再附着」策略（launch / PID 附着都守）。改为复用 PID 附着的就绪门，
  `siglus_child_readiness_test.cpp` 加放置守卫（删掉门的源码反例使守卫失败，退出码 91）。
  **这不是 CLANNAD 卡死的修复**：去掉就绪门的早注入对照 3 次均未卡死。
- **备注**：
  - 日文剧本：Steam 版要保持简体中文语言，再覆盖社区日语补丁 v1.1（Steam 指南 2213979247；只含
    `GameexeZH.dat`、`dat/text*.dbs`、`g00/`、`mov/` 与日文字体，无可执行文件）。台词正文在
    `dat/text*.dbs`。目录布局仍是 `GameexeZH.dat` + `SceneZH.pck`，正是本 bug 的后缀布局。
  - 离线候选：一次性探针以映像装载 exe 逐族跑查词结构解析器，`luna_scenario=1`，其余三族 0，唯一命中。
  - 运行期（2026-09-25，原始 `steam://run` 路径，打过日语补丁）：
    - 文本：`siglus_text_owner=kNativeOwned`，由 SiglusEngine 原生消息 hook（src=4）产出，逐句与画面一致
      （「一面、白い世界…」「「はぁ」」…）。
    - 语音：第 50 句「「はぁ」」落盘 `fushi_textseq50_z0414.ovk_0.ogg`，与 `koe/z0414.ovk` 第 0 条目
      （13967 B，偏移 1028）SHA-256 一致 `4728EF76CB1888704B64A8E29E2CC193435C6D826E67E6F75D4612B005F6E67A`；
      后续 13 句有配音台词都按文本序号配对落盘。
    - 查词：以测试工具扮演 host 发布 `NativeOnly + NativeInputAllowed`（与 Fushi `activeNative` 时同一位）后，
      几何提供者为 EngineExactLayout/Siglus。Shift 与单击都命中正确字符（如 `[3,+1]`=白、`[5,+1]`=世、
      `[1,+1]`=は、`[2,+1]`=ぁ，含多行台词第 2 行），单击字形**不推进**，单击空白正常推进；
      打字机播放中点已显示的字 5/5 不跳句（游戏自身补全整句）。
    - 未经 host 准入时 `PublishHit` 以 `kHitPublicationRejected` 拒绝，这是 Siglus 作为 NativeInputGated
      provider 的设计，不是缺陷。
  - **未复现的卡死**：注入状态下两次观察到主线程停在窗口过程里的 D3D9 `Reset` 循环
    （`SiglusEngine_Steam.exe+0x2639b0`：`Sleep(100)` + `device->Reset` 返回 `D3DERR_DEVICELOST`）。一次在补丁后
    首次启动，一次在用户游玩后。不注入、早注入 ×3、最小化/还原、Alt+Enter 全屏往返、最大化、同步/异步改尺寸、
    Steam 覆盖层开关、连续 150 余句游玩均未复现；dump 与栈解析未入库。用户反馈两次卡死时正在用远程桌面，
    停用远程桌面后按原始路径（Release 与带 PDB 的同源 helper 各一局）又推进约 125 句（含查词回归 38/40，
    两例失败为剧本自动推进落入点击时间窗的测量误差）均未卡死。结论：与远程会话让 D3D9 设备持续丢失
    （`Reset` 恒返回 DEVICELOST）相符；非远程会话下未观察到，不作为 hook 缺陷处理。
  - 未做：真 Fushi app 内弹窗与真卡写入 E2E；`engine-support.yaml` 未改（verified 引擎声明受哈希白名单冻结）。

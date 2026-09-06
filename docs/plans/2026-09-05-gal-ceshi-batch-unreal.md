# ceshi 批量 galgame 适配 · Unreal Engine（IoStore）骨架

**状态：`implemented_unverified`。** 本轮只到 `text_observed` / `pcm_observed`，
没有走过任何一句台词，因此 `text_thread_selected`、`resource_observed`、`paired`、
`card_e2e` 全部 `not_run`，不得宣称「支持 Unreal」。

## 为什么是这个引擎

批量盘点时发现队列里的「昨日魔女今日的梦 1.0 汉化版」此前被记作 **Unity**，
实际是 **Unreal Engine 5**（`kinomajo\Binaries\Win64\kinomajo-Win64-Shipping.exe` +
`Engine\Extras\Redist` + IoStore `.ucas/.utoc`）。仓库原有 17 个引擎里没有 Unreal 家族，
这是队列里**唯一真正的新引擎缺口**——其余游戏都命中已有 adapter。

## 身份台账

| 类别 | 事实 |
|---|---|
| 游戏 | 昨日魔女今日的梦 1.0 汉化版（Unreal Engine 5，IoStore 打包） |
| 原始启动入口 | 外层 `kinomajo\kinomajo.exe`（x64，SHA-256 `877ff376…`） |
| 真实游戏进程 | `kinomajo\kinomajo\Binaries\Win64\kinomajo-Win64-Shipping.exe`（x64，SHA-256 `f7018ae7…`，132 MB） |
| 归档 | `Content\Paks\` 下 `global` / `kinomajo-Windows` / `kinomajo-Windows_zh-CN_P` 三套 `.pak`+`.ucas`+`.utoc`；`kinomajo-Windows.ucas` 2.7 GB |
| 音频 | shipping exe **静态导入 `DSOUND.dll`**；UE 树另带 `Engine\Binaries\ThirdParty\Windows\XAudio2_9\x64\xaudio2_9redist.dll`（运行期动态加载） |
| 第三方 | 该汉化版在 shipping 二进制旁附带 `ue4ss\UE4SS.dll` + `ue4ss\Mods\KinomajoTrainer`（Lua 修改器）。**只作台账**：不进判据，Fushi 不加载也不依赖它；记它是因为这意味着同一进程里可能已经有另一个注入器。 |
| helper | 见提交里的 dist 哈希；双架构 CTest 全绿 |

## 判据（量出来的，不是猜的）

`.utoc` 头 16 字节魔数实测为 `-==--==--==--==-`（`2d 3d 3d 2d ...`），三个文件一致，
第 17 字节是版本 `6`。`.pak` 的头**不是**魔数（UE 的 pak 魔数 `0x5A6F12E1` 在**文件尾部**、
偏移随 pak 版本变），而这三个 `.pak` 的尾 64 字节全是零填充。

于是判据锚在 IoStore，两条**同时**成立才匹配（fail closed）：
1. 可执行文件所在目录是 `...\Binaries\Win64`（UE 每平台固定的 shipping 布局）；
2. 上溯两级的 `<Game>\Content\Paks\` 下至少一个 `*.utoc` 以那 16 字节魔数开头。

**只锚 IoStore 是有意的**：UE4.25 之前只出 `.pak`，手上没有 `.pak`-only 样本，
量不到的形状不写进判据。老 UE4 包因此不匹配——这是已知且刻意的覆盖面缺口，
补它需要一个真的 `.pak`-only 样本。

判据本体放在 `include/unreal_launch.h`，是**唯一真相源**：hook 侧的引擎身份
（`hook/adapters/unreal_iostore_profile.h`）和 injector 侧的 `LooksLikeUnrealRuntime`
都调它，不各写一份——判据写两遍迟早分叉，那正是「身份说不清」这类 bug 的温床。

## 运行期测量（injector `--launch --hold`，2026-09-05）

```
hookdiag  = StartupAudioHooksReady | UnityResourceExtractorReady | LunaHostReady
            | LunaConnected | LunaOutputObserved
xaudiodiag = QueueReady | JobQueued | PcmPublished        （voice_clips 持续增长）
decdiag = 0x00000000   unity_events = 0
```

**文本对照**（同一份 helper、同一段标题画面、只差一个开关）：

| 配置 | text_events 稳定值 |
|---|---|
| 默认 | 11 |
| `--luna-pchooks` | **29** |

UE 是 C++ 引擎，台词在进程内、没有 Mono/TJS 那样的脚本宿主可挂，只能靠 LunaHook 的通用
PC hooks 取文本——与 Unity 同理。据此把 Unreal 加进 injector 的
`ShouldAutoUseLunaPcHooks`（提示语相应从「Unity/Mono-style」改成「scripted-host-less
(Unity/Mono/Unreal)」）。

**没有区分是哪条音频后端产出的 PCM**：exe 静态导入 DSOUND 而 UE 树里同时带
xaudio2_9redist，本轮只证到「通用 Windows 音频路径发布了 PCM」，不写成 XAudio2。

## 本轮交付

- `include/unreal_launch.h`（判据唯一真相源）
- `hook/adapters/unreal_iostore_profile.h`（薄封装：取当前模块目录喂给判据）
- `hook/adapters/unreal_iostore_adapter.inc`（`kText | kPcmAudio`，无引擎专属 hook）
- `profiles/unreal_iostore.json`、`engine-support.yaml` 第 18 条、`docs/engine-support.md` 重生成
- `injector/injector_main.cpp`：`LooksLikeUnrealRuntime` + 自动开 PC hooks
- `tests/unreal_iostore_adapter_test.cpp`（CTest；真临时目录验完整布局 / 无归档 / 魔数不对 /
  目录形状不对，外加路径拆分的空串、纯分隔符、无父目录三个边界）
- `tests/fixtures/unreal_iostore_replay.json` + `fushi/test/mining/unreal_iostore_pairing_test.dart`
  （两棵树逐字节一致，由 cmvs 那条目录枚举守卫自动覆盖）

## Next gate

第一个未通过的边界是 **`text_thread_selected`**：需要在真机上走进一句真台词，
确认 LunaHook 的哪个线程携带对白（而不是标题画面 UI 串）。最小动作：
起游戏 → 进入正篇第一句 → `fushi_voice_ring_probe` 看 `text_events` 与线程分布 →
用工作台确认所选线程的文本是台词。**在此之前不得给 Unreal 记任何 `verified_games`。**

其后依次是：`resource_observed`（IoStore 解包后的 SoundWave 读取接缝，位置只能在真机上定）、
`paired`、`card_e2e`。

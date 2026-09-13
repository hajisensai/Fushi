# ceshi 批量 galgame 适配 · Unity（Mono 运行时）引擎骨架

样本：**カスタムメイド3D2 CHU-B LIP**（KISS，2015-09，零售光盘 MDF）。
状态 `implemented_unverified`，`verified_games` 为空。

## 怎么找到它的

这张盘原本只被分类成「Unity (Mono)」就放下了，理由是 `engine-support.yaml` 的
`unity_il2cpp` 条目里明写着「Unity Mono is a separate Phase 4 target and is not covered by
this IL2CPP claim」——仓库早知道不覆盖。

真正让它变成可动工的，是 **BUG-2149 的 adapter 运行期读数**：把 CM3D2 跑起来后，
`[adapters]` 里**没有 `unity_il2cpp` 行**。这条缺口第一次在**活进程上被看见**，
而不是只存在于一句 known_limitation 里。

## 身份台账

| 类别 | 事实 |
|---|---|
| 游戏 | カスタムメイド3D2 CHU-B LIP（KISS，2015-09） |
| 游戏 exe | `data\CM3D2OHx64.exe`（x64，SHA-256 `5bb03fe8…`）与 `data\CM3D2OHx86.exe`（x86，`7d79c236…`）并存 |
| 托管层 | `CM3D2OHx64_Data\Managed\Assembly-CSharp.dll` 等一整套 Mono 程序集 |
| 运行时 | `CM3D2OHx64_Data\Mono\mono.dll` |
| **没有** | `UnityPlayer.dll`、`GameAssembly.dll`、`il2cpp_data\` |

**「没有 UnityPlayer.dll」是这条 adapter 存在的全部理由**：老 Unity（5.x 一代）把引擎静态
链进 exe。而仓库里 `UnityIl2CppAdapter::probe()`（要 `UnityPlayer.dll` + `GameAssembly.dll`）
与 injector 的 `LooksLikeUnityRuntime()`（要 `UnityPlayer.dll`）都以它为必要条件——
于是这一族游戏两边都不认领。

## 判据

三条，前两条正向、第三条否定，同时成立才匹配（fail closed）：

1. `<exe 主名>_Data\Managed\Assembly-CSharp.dll` 存在；
2. `<exe 主名>_Data\Mono\mono.dll` 存在（Mono 运行时，IL2CPP 没有）；
3. exe 同级**不得**有 `GameAssembly.dll`。

第三条是**与 `unity_il2cpp` 的显式互斥门**。两个 adapter 同时认领同一局，registry 的引擎
身份汇总就说不清是哪家，而那份汇总是用户界面上「这游戏支持到哪一步」的唯一来源。

**判据不要求 `UnityPlayer.dll`** —— 要求了就等于把本条 adapter 要补的那个缺口原样复制一遍。

### 真实数据上的复核

CTest 验的是合成临时目录。另用 Python 复刻同一判据跑真实目录：

```
positive  CM3D2OHx64 -> True      positive  CM3D2OHx86 -> True
negative  manosaba_Ver1.0.3 (Unity IL2CPP) -> False
negative  Sakura Swim Club  (Ren'Py)       -> False
negative  chronoclock-trial (CMVS)         -> False
negative  TenShiSouZou_R18  (KiriKiri)     -> False
negative  _run_himelove     (AOS/SFA)      -> False
```

manosaba 是**双重**不命中：既有 `GameAssembly.dll` 触发否定门，本身也没有
`Managed\Assembly-CSharp.dll`。互斥不是纸面约定。

## 运行期测量（2026-09-05）

`injector --launch --hold data\CM3D2OHx64.exe --japanese-locale`：

```
hookdiag = StartupAudioHooksReady | UnityResourceExtractorReady | LunaHostReady
           | LunaConnected | LunaOutputObserved
luna_active = 1   text_events = 7（标题画面）
voice_clips = 981（非静音，通用源 PCM）      unity_events = 0
[adapters] 里没有 unity_il2cpp 行
```

**PC hooks A/B（同一段标题画面、只差一个开关）**：

| 配置 | text_events |
|---|---|
| 默认 | 7 |
| `--luna-pchooks` | 7 |

**没有收益，所以没有改 injector 的自动 PC hooks 判据。** 这与 Unreal 那次形成对照：
那次是 11→29 才据此改的。不拿「顺手加上」当理由扩大 hook 面。

## Proved / Not proved / Next gate

**Proved**
- `process_found` / `helper_ready` / `ipc_ready`
- `text_observed`（LunaHook 有输出，但只有标题画面串）
- `pcm_observed`（981 clips，非静音）

**Not proved（一律 not_run）**
- `text_thread_selected` / `resource_observed` / `paired` / `loopback_observed` / `card_e2e`

**Next gate**：`text_thread_selected`。最小动作：起游戏 → 进入有台词的场景 →
看 LunaHook 哪个线程携带对白（而不是 UI 串）。
`unity_events=0` 说明既有的 Unity 资源提取器对这一族没有产出，逐句语音资源层因此未做；
要往下走得先在真机上定位它自己的读取路径，静态阶段不猜 hook 面。

**另一条尚待补的**：`[adapters]` 里看到 `unity_mono=probe:1/installed:1` 需要
BUG-2149（PR #1219，IPC v23）先落地——本分支基于它之前的 develop，读数点还不在树上。
#1219 合入后并进来复跑一次即可，判据本身已按上面的方式在真实目录上复核过。

## 本轮交付

- `hook/adapters/unity_mono_profile.h`（三条判据，含互斥否定门）
- `hook/adapters/unity_mono_adapter.inc`（`kText | kPcmAudio`，无引擎专属 hook）
- `profiles/unity_mono.json`、`engine-support.yaml` 第 20 条、`docs/engine-support.md` 重生成
- `tests/unity_mono_adapter_test.cpp`（CTest，8 组：完整布局 / 缺 Mono / 缺 Managed /
  **有 GameAssembly.dll 时必须让路** / exe 主名对不上 / 退化输入 / 同名目录不算文件 / 本进程目录）
- `tests/fixtures/unity_mono_replay.json` + `fushi/test/mining/unity_mono_pairing_test.dart`
  （两棵树逐字节一致，由既有的目录枚举守卫自动覆盖）

## 给下一轮的提醒

样本解压在 `ceshi\_run_cm3d2`（5.9 GB），是本轮为测量抽的，**可以直接删**。

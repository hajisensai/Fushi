# ceshi 批量 galgame 适配 · AOS / SFA 引擎骨架

样本：**姫様ＬＯＶＥライフ！**（Princess Sugar，2015-08，零售光盘）。
状态 `implemented_unverified`，`verified_games` 为空。

## 怎么找到它的

批量盘点时这张盘属于「8 个没有 exe 的目录」之一，一直没进队列。本轮发现
**光盘不必安装就能定引擎**：`7z l <iso>` 列目录，游戏 exe 与归档通常就在盘上。
这张盘上是 `bgm/cv/grp/scr/se.aos` + 一个以作品名命名的 x86 exe。

## 身份台账

| 类别 | 事实 |
|---|---|
| 游戏 | 姫様ＬＯＶＥライフ！（Princess Sugar，2015-08） |
| 游戏 exe | 全角日文作品名，x86（machine 0x14c），862720 B，SHA-256 `fa965f07…` |
| 导入 | DDRAW / DINPUT / **DSOUND** / d3d9 / d3dx9_43（DirectSound 是唯一音频 API） |
| 归档 | `bgm.aos` 61 MB / `cv.aos` **675 MB（语音）** / `grp.aos` 2.99 GB / `scr.aos` 2.5 MB / `se.aos` 14 MB |
| 运行期主窗口类 | **`SFA`** |

## 判据（量出来的）

5 个归档的头**全部**是同一形状：

```
偏移 0..3  : 00 00 00 00
偏移 4..7  : u32
偏移 8..11 : u32
偏移 12..  : 该归档自身的文件名，ASCII、NUL 结尾
```

例：`scr.aos` → `00 00 00 00 | 31 2c 00 00 | 20 2b 00 00 | "scr.aos\0…"`。

判据就取「**头里写着自己的文件名**」：这件事很难被别家格式偶然撞上，
而且它顺带把「后缀是 `.aos` 但内容不是」挡在门外。
**五个归档全部验过**，不是只看两个就外推。

窗口类 `SFA` 是更强的运行期信号，但**进不了判据**——身份要在进程启动早期就给出答案，
那时窗口还不存在。它只作台账，以及将来做运行期二次确认的材料。

## 运行期测量（2026-09-05）

**先复现原始失败路径**：把盘上文件复制到目录后直接起，游戏只弹一个 `#32770` 对话框，
内容是「初回起動時はディスクが必要です」——要原盘。没有窗口、没有文本、没有音频。

**挂载原盘后**（`Mount-DiskImage` 只读挂载，测完 `Dismount-DiskImage`；
**没有安装、没有写注册表**）：

```
visible window class = SFA
hookdiag = StartupAudioHooksReady | LunaHostReady | LunaConnected
PCM      = 44100/2/16，voice_clips 涨到 57，peak 14570（非静音）
luna_active = 0   text_events = 0     （标题画面）
```

## Proved / Not proved / Next gate

**Proved**
- `process_found` / `helper_ready` / `ipc_ready`
- `pcm_observed`：通用 Windows 音频路径发布了非静音 PCM

**Not proved（一律 not_run，不猜）**
- `text_observed`：LunaHook 连上了但没有输出。这个引擎在 vendored LunaHook 里
  有没有对应 hook，本轮**没有能作证的手段**（DLL 里查不到引擎名字符串），
  所以 adapter **刻意不声称 `kText`**——不拿「大概有」当能力声明。
- `text_thread_selected` / `resource_observed` / `paired` / `loopback_observed` / `card_e2e`

**Next gate**：`text_observed`。最小动作：挂盘起游戏 → 进入正篇第一句 →
`fushi_voice_ring_probe` 看 `text_events` 是否离零、Luna 是否出线程；
若始终为零，则第一个未通过边界变成「这个引擎需要自带文本 hook」，
那要先在真机上定位它的显示函数，静态阶段不猜 hook 面。

逐句语音资源层（`cv.aos`）明确未做，理由同上。

## 本轮交付

- `hook/adapters/aos_sfa_profile.h`（自命名归档头判据）
- `hook/adapters/aos_sfa_adapter.inc`（**只** `kPcmAudio`）
- `profiles/aos_sfa.json`、`engine-support.yaml` 第 18 条、`docs/engine-support.md` 重生成
- `tests/aos_sfa_adapter_test.cpp`（CTest；真临时目录 8 组：真实头 / 名字对不上 /
  前 4 字节非零 / 名字被截断 / 大小写不同 / 非 ASCII 名 / 空目录与过短文件 / 本进程目录）
- `tests/fixtures/aos_sfa_replay.json` + `fushi/test/mining/aos_sfa_pairing_test.dart`
  （两棵树逐字节一致，由既有的目录枚举守卫自动覆盖）

## 给下一轮的提醒

盘上抽出来的运行目录在 `C:\Users\wrds\Downloads\Compressed\ceshi\_run_himelove`（3.5 GB），
是本轮为测量临时抽的，**可以直接删**。真要继续这个引擎，记得每次都要挂原盘。

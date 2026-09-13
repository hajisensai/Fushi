## BUG-2253 · 游戏日文转区默认自动，没选过就替用户改了启动方式
- **报告**：2026-09-07（用户："游戏关闭自动转区…改成用户选择"）
- **真实性**：✅ 真 bug（产品决策类）。根因 `fushi/lib/src/mining/galgame_japanese_locale.dart:47`（修复前）

  `kGalDefaultJapaneseLocaleMode` 是 `GalJapaneseLocaleMode.auto`，而 galgames 表的
  `japanese_locale_mode` 列缺省是空串、空串在解析层回落该常量。于是**从没为某个游戏
  选过档位**的用户，一启动游戏就会走上自动链路：

  1. `galgame_audio_source.dart:1713` — launch 且档位 auto ⇒ 无条件跑
     `_judgeJapaneseLocaleNeed(exe)`：读 exe 前 16MB、扫目录顶层 ≤2000 项、
     读 ≤20 个文本文件。
  2. `galgame_japanese_locale.dart:371-377` — 判为 needed + 系统 ACP≠932 + 32 位
     ⇒ **直接返回 true**，不询问。
  3. `galgame_audio_source.dart:1749` → injector 追加 `--japanese-locale`，
     经 Locale Emulator `LeCreateProcess` 以 CP932 重新拉起用户的游戏进程。

  另有一条不问自取的换档：`gal_hook_session_controller.dart:1608-1638`，转区拉起的
  进程秒死时（BUG-2126）自动以 `off` 递归重拉一次。

  转区不改系统设置（每进程注入），但它改变了**用户游戏的启动方式**，而用户从没
  表达过要这个。判错的代价还不对称：该转没转只是显示乱码，用户看得见、去右键菜单
  改即可；不该转却转了会让汉化版 `MultiByteToWideChar(CP_ACP, ...)` 解出非法序列、
  字表越界**直接闪退**，用户完全不知道是 Fushi 干的。

- **[x] ① 已修复** — `kGalDefaultJapaneseLocaleMode` 改为 `GalJapaneseLocaleMode.off`
  （与 `magpie_upscaling.dart` 的 `kMagpieDefaultUpscalingMode` 同纪律）。空串的语义
  本来就是「用户从没选过」，不是「用户选了自动」——主动选自动的行落的是字面量
  `'auto'`，那条路径不受影响，仍然自动判定、仍然有 auto→off 秒死回退。

  连带效果：默认档下连第 1 步的探测都不再跑（门控就是 `mode == auto`），省掉每次
  启动读 exe 16MB + 扫目录。

  DB 数据不动、迁移代码不动（v75 仍回填空串），变的只是空串的**解析语义**，所以
  不需要新迁移阶梯；`tables.dart` 与 `database.dart` 里断言旧语义的注释已同步更正。

- **[x] ② 已加自动化测试** — `fushi/test/mining/galgame_japanese_locale_test.dart`：
  - 「空串/null/脏值一律回落 off，不是 auto」（原用例断言的是 auto，已反转）
  - 「主动选过 auto 的游戏不受影响，仍然自动判定」——钉死本次改动**不**波及显式选择
  - 「没选过的游戏：证据再齐也不转区」——用「32 位 + 系统非日文区 + 证据 needed」这组
    最容易触发转区的输入，确认默认档下依然不转。改回 auto 兜底会让这条立刻红。

- **备注**：四个既有用例原先靠「缺省档 = auto」来构造 auto 场景（`galgame_audio_test.dart`
  的 processStarter 甚至直接断言 injector 参数里有 `--japanese-locale`），默认值一变
  就测不到 auto 了。已全部改为**显式传** `japaneseLocaleMode: GalJapaneseLocaleMode.auto`
  ——测 auto 行为就该显式给 auto，本来也不该依赖缺省值。

  **已知代价**（用户 2026-09-07 明确选择「默认关闭、不弹窗」时接受）：off 档不记任何
  转区事件，所以日文原版首次乱码时会话状态卡上不会有任何提示，用户需要自行到游戏
  右键菜单把「日文转区」改成自动或始终开启。若日后要补可见性，最小改法是让 off 档
  在检测到疑似乱码时出一条只读提示，而不是恢复自动转区。

  超分（`magpie_upscaling.dart`）本次**未改**：它的缺省档早已是 `off`（BUG-1191），
  全仓唯一写入点是用户在游戏右键菜单里手选，不存在「没选过就自动开」的路径。

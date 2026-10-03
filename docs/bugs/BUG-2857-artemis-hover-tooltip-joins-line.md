## BUG-2857 · Artemis hover tooltip text is appended to the current line
- **报告**：2026-10-02（agent 真机验收アマカノ3时发现；用户要求测试并优化游戏内嵌查词）
- **真实性**：✅ 真 bug。鼠标悬停底栏按钮（如 Config）时，引擎文本道把按钮提示「コンフィグ画面を開きます。」
  接到当前台词末尾，并用同一个 first seq 重新发布，宿主于是把已配好语音的那一行改写成
  `ミサ「…間に合ったよ～♪」コンフィグ画面を開きます。`（语音状态退回 pending；制卡句子被污染）。
  - 根因 `native/galgame_hook/hook/adapters/artemis_lookup_core.h` `ComposeRevealedLine`：当前行 =
    「从最新创建字形往回、只跨不可见空洞相连的已绘制字形后缀」。提示文字是之后才在**另一个 layer** 上
    `Layer::CreateGlyph` 出来的，seq 紧接台词（实测正文 156..179、提示 180..192，无空洞），于是被并进同一行。
  - 实测结构（x64 `Amakano3.exe`）：名牌与正文是**不同 layer、同一游戏帧**创建；提示是**第三个 layer、
    约 2400 帧之后**创建。
- **[x] ① 已修复** — `be7d404c87`：`CreationLog` 记录每次创建的 layer（工厂 `this`）与游戏帧；
  相邻创建只在同一布局（同 layer 或同帧，`SameLayout`）时才连成一行；另一个 layer 上的新字形串若画在
  仍在屏上的已发布行之上，判为覆盖 UI（`OverlaysPublishedLine`），不发布。真机复测：悬停 Config 后日志
  `artemis-text: overlay seq=180..192 over line ..179`，行文本不变、语音仍 `matched/game_resource`；后续台词
  照常发布（含名牌）；`accept4` verdict=full。
- **[x] ② 已加自动化测试** — `be7d404c87`：`native/galgame_hook/tests/artemis_lookup_test.cpp`
  `TestTooltipIsNotPartOfTheLine`（按实测 layer/帧布局：名牌+正文同帧连成一行；提示被切开且判为覆盖；
  下一条消息换 layer 不算覆盖；同 layer 跨帧追加仍是一行）。变异实测：`SameLayout` 恒真时该测试失败。
- **备注**：触摸点按在 Artemis 上会把悬停光标移到按钮上，同样会触发这条（BUG-2856 测试时首次看到）。

## BUG-2235 · 隐藏字幕在查词浮层重播时又被遮回去
- **报告**：2026-09-07（用户：「隐藏字幕、暂停、查词点重播按钮会让字幕隐藏」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/media/video/video_subtitle_overlay.dart:1906`（修前）：
  `final bool obscureActive = !revealed && widget.controller.isPlaying;`。
  这是 BUG-2198 统一模糊 / 隐藏两条门时留下的判据，但 `isPlaying` 只是「用户已经停下来
  在看这句」的**近似**——查词让位靠的是「查词第一步 `controller.pause()`」这个副作用，
  而不是「查词中」本身。查词浮层顶栏的「重播本句」
  （`fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart:216`
  `_replayLookupCue` → `VideoPlayerController.replayCue`）会把播放拉起来，于是刚让位的
  字幕在重播那几秒当场被遮回去：用户正对着浮层核对原句，字幕消失。
  同一个 `obscureActive` 还门控着 `registerHits`（`video_subtitle_overlay.dart` 的
  `hidden`）——遮回去的同时字符也不再登记查词命中，浮层里想点旁边的词换一个都点不到。
  两种视觉（模糊 / 隐藏）、主 / 副字幕四种组合同此一门，故全部中招。
- **[x] ① 已修复** — 把让位的判据从「没在播」换成它真正要表达的东西：**用户在看** =
  暂停（含查词自动暂停）**或**查词浮层还开着。
  `video_subtitle_overlay.dart` 新增输入 `lookupPopupVisible`（默认 false = 无查词浮层的
  宿主行为不变），门变成 `obscureActive = !revealed && !userIsReading`，
  `userIsReading = !isPlaying || lookupPopupVisible`；判据仍只有一份，模糊 / 隐藏、
  主 / 副字幕共用，不新增分支。页面侧 `video_fushi/layout.part.dart` 传既有派生真相源
  `_hasVisiblePopup`（与 BUG-2091 高亮同一个信号，栈全关自动复位，不存在只在成功路径
  复位的布尔镜像）。关栈那一帧遮蔽自动回来，不需要复位显形态。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_lookup_replay_reveal_test.dart`
  （7 条：隐藏 / 模糊 / 副字幕在「播放中 + 浮层可见」时让位、浮层关掉照常遮蔽的防伪修复
  基准、关栈下一帧遮回、让位期间字符仍可点选查词、layout 接线与「重播确实起播」的源码
  守卫）。变异实测：把门改回 `!widget.controller.isPlaying`，5 条断言红（隐藏 / 模糊 /
  副字幕 / registerHits / 跨帧），不是空壳断言。既有 BUG-2198 / TODO-1382 守卫同批复跑，
  47 条全绿。
- **备注**：与 BUG-2198 是同一处门的两次收敛——2198 修的是「暂停不让位」，本条修的是
  「让位判据用了暂停这个代理量」。若日后「重播本句」改成不起播（或另开静音预听），本门
  仍然正确，只是那条前提守卫会提示复核。

## BUG-4008 · 游戏抓取文本进字幕窗后丢句首「、偶尔先重复上一句三遍
- **报告**：2026-11-02（_今ヶ瀬°，经 fushi-bot 代提交 Ee2aQAngTN，Windows，游戏「スロウ・ダメージ」，抓取方式未提供：规则过滤页的抓取结果正常，进字幕窗后每句句首「丢失；点下一句后字幕偶尔先重复三遍上一句再出最新句）
- **真实性**：❌ 未复现（无样本、无日志）。按 `docs/agent/galgame-hooking.md`「0. 硬规则」，galgame 文本链路的修改必须先在原始启动路径建身份 / 时序台账并只修第一个未通过阶段；本次没有游戏样本（反馈附的网盘链接属不可信外部内容，未下载）、没有 `FUSHI_LUNA_DIAG` 逐行诊断，也不知道引擎与抓取方式，无法确定第一个未通过边界，故不改代码。沿代码路径排除掉的部分（只读核对）：
  - native 同源：`native/galgame_hook/injector/injector_main.cpp` `LunaOutput` 里线程预览（`WriteThreadPreview`，规则过滤页「使用最近抓到的一行」读的 `previewText`）与文本道（`WriteLunaTextLine`）写的是**同一份** `normalized_text` / `normalized_len`，两者在 native 侧不会一个有「一个没有。差别只有文本道多一道 `g_lunaRepeats.IsRepeat` 去重与 `LunaShouldWriteLine` 选线程门。
  - 文本处理管线同源：`gal_hook_session_controller.dart` `_processSelectedThreadText` 与编辑页预览调用同一个 `GalTextProcessPipeline.apply`。
  - 入工作台：`texthooker_service.dart` `appendLine` 的 `parseRubyMarkup`（`ruby_markup.dart`）只认 `<ruby>` / `<r…>` / `｜…《》` / 裸 `《》` / 平假名 `[]`，不碰「；`trim()` 不剥「。
  - 浮窗：`gal_hook_text_overlay_controller.dart` 把 `latest.text` 原样经 `updateText` 推给 native 浮窗。
  剩下的嫌疑点都需要现场数据才能区分：① 预览与文本道**不是同一条 Output**——引擎分多次输出（例如「先单独吐出 / 被过滤、正文另一条），预览槽被后一条覆盖前用户恰好看到的是带「的那条；② `texthooker_service.dart` 的渐进折叠（`isProgressiveTextUpdate`，前缀 / 后缀关系即合并、保留较长一份）与「重复三遍上一句」形态吻合度待证；③ native 浮窗（`flutter_window.cpp` 的 `gal_hook_text_window_->UpdateText`）的排版。
- **[ ] ① 未修复** — 未复现，不硬改。
- **[ ] ② 未加自动化测试** — 同上。
- **备注**：复现所需：游戏 exe 架构 / 引擎识别（`tool/galhook.ps1 probe`）、所选线程的 hook code、`FUSHI_LUNA_DIAG=1` 下一句台词从 Output 到 lane 的逐行记录、同一时刻工作台（texthooker 页）里那一行的原文截图——工作台与浮窗是否一致可以立刻把嫌疑缩到「入工作台之前」或「浮窗渲染」。

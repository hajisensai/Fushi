## BUG-1264 · 纯字幕模式下行内 \c 主色穿透导致 OP 字幕变黑

- **报告**：2026-07-31（用户：关掉「尊重字幕自带样式」后，OP 字幕变黑了，附截图）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:1847`（修复前）
  —— `_styleForGrapheme` 里行内 `\c`/`\1c` 主色 **未按 `respectAssStyle` 门控**：

  ```dart
  Color? spanColor = span.colorArgb != null ? Color(span.colorArgb!) : null;
  ```

  它是纯字幕模式（`respectAssStyle` 关，BUG-915 定义的 asbplayer 语义）里**最后一条漏网的
  颜色通道**。同族属性早已全部门控：

  | 通道 | 门控位置 |
  |---|---|
  | `\3c` 描边色 | `_resolveStroke` `video_subtitle_overlay.dart:1678` |
  | `\1a` 填充透明度 | `_styleForGrapheme` `:1846` |
  | cueStyle 主色（V4+ Styles PrimaryColour） | `_styleForGrapheme` `:1767` |
  | `\t` 颜色动画 | `_applyDynamicFill` `:1896` |
  | 卡拉 OK SecondaryColour | `_applyDynamicFill` `:1896` |
  | **行内 `\c` / `\1c` 主色** | **无（本 bug）** |

  **失败链条**（OP 歌词是多层卡拉 OK ASS，一句拆成多条同时事件）：

  1. `respectAssStyle` 关 → 走纯字幕模式，`_buildSubtitleLayer` `:772` 用
     `_uniqueByText(cues)` 按文本去重，**只保留发现顺序第一条**（cue 文件序号最小者，
     通常是最底的描边/光晕层）。
  2. 该层的 `\c` 是黑色（它在原设计里靠上面的文字层盖住，自己只提供描边/辉光）。
  3. 本该给它兜底的白描边 `\3c` 与透明填充 `\1a` **都被正确门控掉了**，唯独黑色 `\c`
     穿透生效。
  4. → 整句渲染成裸黑字。普通对白无行内 `\c`，所以只有 OP 黑——与用户观察一致。

  同时这与开关自身的契约冲突：i18n `video_setting_subtitle_respect_ass_hint` 明写
  「关闭则**一律使用你的外观设置**」。旧行为被 `video_subtitle_overlay_markup_test.dart`
  以 "Inline \c red is a legacy span style -> applies even when off" 固化，但该测试标题
  写的却是 `OFF: unified style wins`，自相矛盾。

- **[x] ① 已修复** — `video_subtitle_overlay.dart` `_styleForGrapheme`：行内 `\c`/`\1c` 与
  兄弟通道同源门控 `(respect && span.colorArgb != null)`，关时回落 `baseColor`（用户
  `textColor`）。同步改写方法文档：纯字幕模式 = 颜色语义整体归零，只保留 `\i \b \u \s`
  文本语义与历史 `\fs` 裸像素字号。提交见分支
  `worktree-bug-subtitle-plain-mode-inline-color`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_text_color_test.dart`
  新增 group「BUG-1264 纯字幕模式颜色语义归零（行内 \c 不穿透）」三条 widget 测试：
  ① OFF + 行内 `\c` 黑 → 填充恒用户 textColor；② **OFF + 多层卡拉 OK 同句去重（原始失败
  路径）** → 任何一层拷贝都不得带进 ASS 黑色；③ ON + 行内 `\c` → ASS 主色照常优先（防
  反向破坏尊重路径）。并改正 `video_subtitle_overlay_markup_test.dart` 里固化旧行为的
  断言（契约变更，非回归）。
  **变异实测**：临时回退门控后，上述 ①②与 markup_test 共 3 条立刻转红
  （`FLUTTER TEST VERDICT: FAILED`），确认守卫不是假绿。
- **备注**：
  - 相邻隐患（本次未改，未获用户确认前不扩大范围）：同一段 `:1862` 的行内 `\fs` 在
    `respectAssStyle` 关时仍按**裸像素**穿透（ASS 的 fs 是 PlayRes 空间像素，直接当 Flutter
    逻辑像素用，且与用户字号滑块完全脱钩）。按「关闭则一律使用你的外观设置」的契约，它
    同属应归零的外观通道；用户本次只报颜色，故留档待定。
  - 未做真机复验（本轮只有 widget 层证据 + 用户截图）。

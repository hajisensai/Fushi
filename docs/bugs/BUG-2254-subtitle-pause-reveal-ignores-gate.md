## BUG-2254 · 关掉「悬停或点击显形」后，暂停仍会揭开被隐藏的字幕
- **报告**：2026-09-07（用户：咕星总督）「我明明隐藏字幕了，暂停的时候字幕还是会出现」「我关掉了（那个开关），暂停时还是会显示字幕」
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_subtitle_overlay.dart:1291`（修前）——遮蔽让位判据
  `userIsReading = !controller.isPlaying || lookupPopupVisible` 是**无条件**的，完全不看
  `obscureRevealOnInteraction`（设置项「悬停或点击显形」，`video.subtitle.obscure_reveal`）。
  该总闸只被两处消费：悬停的 `MouseRegion`（`video_subtitle_overlay.dart:1913` 附近的
  `hoverRevealEnabled`）与遮蔽热区的 `onTap`。于是显形有三个来源、闸只管住两个：
  暂停（含查词自动暂停，BUG-2198）与查词浮层可见（BUG-2235）这条**最常走**的自动路径
  照旧揭开遮蔽——用户关掉开关后，一按暂停字幕就冒出来，开关等于半失效。
- **[x] ① 已修复** — 把自动显形并入同一个闸：`userIsReading = obscureRevealOnInteraction && (!isPlaying || lookupPopupVisible)`
  （`video_subtitle_overlay.dart` `_buildSubtitleLayer`）。开着 = 历史行为（BUG-2198 / BUG-2235 原样保留）；
  关掉 = 遮蔽恒定生效，暂停 / 查词 / 悬停 / 点击都不揭开。设置项文案同步改成「暂停或悬停时显形」
  （`video_setting_subtitle_obscure_reveal` / `_hint` 的 en + zh-CN 值，key 未变）。
  **已知权衡**：关掉开关后查词浮层期间字幕也保持遮蔽，且 `registerHits` 随 `hidden` 关闭字符命中登记，
  即「关掉开关 + 隐藏」时不能在字幕上点字查词。这是用户显式选择「遮蔽始终保持」的后果，不是回归；
  若后续有人要「查词仍显形但悬停不显形」，需要把闸拆成逐来源开关，而不是把这条特例加回去。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_hide_hover_reveal_test.dart` 新增第 ⑪ 组
  「自动显形（暂停 / 查词浮层）同受总闸」5 条 widget 行为用例：关闭闸 + 隐藏 + 暂停 / 关闭闸 + 模糊 + 暂停 /
  关闭闸 + 查词浮层可见 三条断言仍遮蔽，另两条开闸基准防恒真（BUG-2198 / BUG-2235 行为不被改坏）。
- **备注**：同轮用户还报「字幕遮蔽选『关闭』后按快捷键又变回隐藏」——查证为 `videoToggleSubtitleHide`
  （i18n 名「切换隐藏字幕」，`video_fushi_page.dart` `_toggleSubtitleHide`）的 toggle 语义：
  `hide → none`，其余状态（含 none）→ `hide`。设置面板与快捷键写的是同一份偏好
  （`setVideoSubtitleObscureModeDual` 最终都落 `appModel.setVideoSubtitleObscureMode`），不存在双源不同步，
  故不作为 bug 修复；属期望与命名的落差，另议。

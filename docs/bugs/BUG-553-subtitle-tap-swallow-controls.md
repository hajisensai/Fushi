## BUG-553 · 字幕盒吞掉唤出视频控制条的点击

- **报告**：2026-07-05（用户：TODO-1202）
- **真实性**：✅ 真 bug（既有 bug，非最近回归；被 TODO-1196 让 10-bit 视频能出画后暴露）。
  根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:445`（整片
  `GestureDetector(behavior: HitTestBehavior.translucent, onTapDown/onTapUp …)`）+
  `hibiki/lib/src/pages/implementations/video_hibiki/layout.part.dart:314`（`Positioned.fill`
  的 `VideoSubtitleOverlay` 叠在 `layout.part.dart:293` 的 media_kit `AdaptiveVideoControls`
  之上）。
  - 症状：移动端**有字幕在屏**时点画面（尤其字幕所在的底部中央）唤不出视频控制条。
  - 机理：字幕盒在 Stack 上层、先 hit-test；旧的整片 translucent GestureDetector 对**落在盒内
    的任何点**都无条件把自己加入命中路径、赢下手势竞技场 → media_kit 的 show-controls `onTap`
    （`third_party/…/media_kit_video/…/controls/material.dart` 的 `onTap()`）被 reject。命中字符
    走查词（正常），但字符间空白 `onTapUp` 的 `hit==null` 什么也不做，且竞技场已被吞 → 既不查词
    也不唤控制条。桌面靠 hover（`MouseRegion opaque:false`）不受影响，移动端无 hover 只 tap 故失效。
- **[x] ① 已修复** — 把整片 translucent `GestureDetector` 换成 translucent `RawGestureDetector` +
  自定义 `_SubtitleCharTapRecognizer`（`isPointerAllowed` 仅在**按下点命中某字符**时才收指针、进
  竞技场；未命中即拒收，让 media_kit 的 `onTap` 独占竞技场胜出 → 点字幕区空白照常唤出/隐藏控制条）。
  保留 `HitTestBehavior.translucent` → 命中/hover hit-test 语义逐字节不变，media_kit 仍在命中路径、
  桌面 hover 与 BUG-198 不回归；命中字符仍赢竞技场查词、截断 media_kit `playAndPauseOnTap`（点字幕
  文字只查词、不顺手暂停）。改动文件 `hibiki/lib/src/media/video/video_subtitle_overlay.dart`。提交见分支尾。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/widgets/video_subtitle_overlay_fallthrough_test.dart`：Stack 下垫计数 GestureDetector
    模拟 media_kit tap 层；点字符→查词触发且**不**穿透（保留「点字幕文字不顺手 toggle」）；点字幕盒内
    字符间空白（超容差）→**不**查词且穿透到下层（唤出/隐藏控制条）。
  - `hibiki/test/media/video/video_subtitle_tap_hit_area_guard_test.dart`：源码守卫——字幕 tap 必须经
    `_SubtitleCharTapRecognizer`（`isPointerAllowed` 门控竞技场）+ 保留 translucent，禁止回退到无条件收
    tap 的整片 `GestureDetector`（真实竞技场时序 headless 跑不了，锁源码结构）。
  - 同步更新 `hibiki/test/media/video/video_subtitle_overlay_test.dart` 的 BUG-198 结构断言（tap 层由
    translucent `GestureDetector.onTapUp` 迁到 translucent `RawGestureDetector`；仍禁 opaque、仍保 hover 透传）。
- **备注**：真机门（手机·安卓）——放**有字幕**的视频，点字幕**字符**应弹查词；点字幕区**空白/画面**应
  唤出/隐藏控制条。视频画面 tap 焦点驱动不适用，需真机人工点验（集成测试禁坐标点击）。

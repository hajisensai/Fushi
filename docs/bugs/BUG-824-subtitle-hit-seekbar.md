## BUG-824 · 点视频进度条被误判成点字幕触发查词

- **报告**：2026-07-15（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:47`（`resolveSubtitleCharHit` 的最近字符兜底容差各向同性）。
  - 视频页字幕层 `VideoSubtitleOverlay`（`layout.part.dart:323`）盖在 media_kit 控制条/进度条（`layout.part.dart:257`）**之上**，是同一 `Stack` 的最顶层，最先被 hit-test。
  - 字幕字符 tap 识别器 `_SubtitleCharTapRecognizer.isPointerAllowed` 只要 `_hitEntryIndexAt(pos) >= 0` 就收下指针、赢竞技场并 reject media_kit 的 onTap（`video_subtitle_overlay.dart:1535-1547`）。
  - 命中内核 `resolveSubtitleCharHit` 第二段「最近字符兜底」用**各向同性**欧氏距离，容差 `clamp(charWidth/2, 10px, ∞)`（36px 字幕半字宽≈18px）。这个容差本为水平「字缝/描边外缘」miss 兜底（TODO-916/971，字缝是水平方向），却被写成各向同性，**垂直向下**也放出 ~18px 裙边。
  - 避让逻辑 `_paddingFor` + `videoSubtitleControlsReserve` 故意把控制条可见时的字幕底缘停在「进度条轨道上缘 + 一点点呼吸间距」（`video_subtitle_style.dart:66-87`），底行字符矩形下缘紧贴进度条。于是向下的 18px 裙边恰好盖住进度条轨道顶部一条带。
  - 用户 **tap（非拖动）**这条带时 → 顶层字幕识别器赢竞技场 → `_handleSubtitleLookupTap` → `_lookupAt` 暂停视频（`_pausedForLookup=true; controller.pause()`）+ 弹查词浮层，seek 被吞（`lookup_favorite.part.dart:49-51`）。拖动 seek 因超 slop 后由 media_kit 的 horizontal-drag 识别器赢过 tap，不受影响——与「点进度条」的描述吻合。
- **[x] ① 已修复** — 把 `resolveSubtitleCharHit` 的兜底容差从各向同性圆改成**方向感知椭圆**：水平半轴保持 `clamp(半字宽, minTolerance=10px, ∞)`（保 TODO-916/971 字缝兜底），垂直半轴收紧到描边级 `edgeTolerance=6px`（覆盖默认软阴影半径 3px + 手指余量），判据 `(dx/tolX)² + (dy/tolY)² ≤ 1`。向下不再放半字宽裙边，tap 穿透到 media_kit 进度条正常 seek。`hibiki/lib/src/media/video/video_subtitle_overlay.dart:47`。提交：`<待填>`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/subtitle_char_hit_tolerance_test.dart` 新增 `BUG-824：垂直兜底容差是描边级` 用例：36px 宽字符正下方 12/15px 的点须 miss（旧 18px 裙边会误命中），且水平半字宽兜底、垂直描边上下缘兜底不回归。8 项全过。提交：`<待填>`。
- **备注**：与 memory 中 BUG-823（切换剧集双音轨 PR#138 草稿）避免撞号，本条用 824。修复仅动一处纯函数，页面/竞技场层叠逻辑不变；待真机在视频播放页 tap 进度条复测「seek 生效、不弹查词」。

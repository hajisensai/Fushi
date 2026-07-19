## BUG-910 · 视频字幕查词点空白想关闭却重复查同一个词

- **报告**：2026-07-19（用户：）
- **现象**：视频播放时点画面底部内嵌字幕某字查词 → 弹词典浮层（正常）。想点浮层外**空白处**关掉浮层继续看视频，却**反复重查同一句里的词**，关不掉。用户强调点的是**空白**、不是字、不是同一个词区域。
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` `_onDismissBarrierTap`（原 `final SubtitleCharHit? hit = _subtitleHitTester.hitTest(globalPos);`）。
  - 查词浮层打开时根 Overlay 铺全屏 dismiss barrier，点浮层外先进 `_onDismissBarrierTap` → `_subtitleHitTester.hitTest(globalPos)` 反查是否点到底部字幕字符，命中即 `shouldSwitchWordOnBarrierTap`（非嵌套 `topVisibleIndex<=0 && hitSubtitle`）→ `_handleSubtitleLookupTap` → `_lookupAt(replaceStack:true)` 重查、保持暂停、浮层不关。
  - 关键：命中反查复用**查词用的胖手指裙边容差** `resolveSubtitleCharHit`（`video_subtitle_overlay.dart`，TODO-971 水平半字宽 ≈18px + BUG-825 描边级垂直边）。这套 halo 本服务「点小字好点中」，但 barrier 判「关闭 vs 切词」也吃它 → 字幕行周围约 18px 的**空白**被误判成「命中字幕」→ 把「点空白想关闭」当成「切词重查」。查词已暂停（`_lookupAt` 置 `_pausedForLookup=true; controller.pause()`），字幕**冻结**在屏，用户在字幕行附近空白反复点 → 反复落进 halo → 反复重查同一句 = 死循环。
  - 佐证：BUG-410 备注原话「位置相关、间歇（落字幕上复现，**落纯空白正常**）」——当初 barrier 命中判定还是精确容差，点纯空白能正常关；TODO-916/971 放宽容差后 barrier 继承了 halo，「落纯空白正常」被打破，退化成本 bug。桌面悬停换词（`_onDismissBarrierHover`）、Shift 查词（`_triggerShiftLookupAtLastPointer`）是查词意图，仍应用宽容差，不受影响。
- **[x] ① 已修复** — 解耦「查词命中」与「barrier 关闭判定」，让 barrier 只在点**落在字形矩形内**才算命中：
  - `resolveSubtitleCharHit`（`video_subtitle_overlay.dart`）加 `bool exactOnly=false`：为 true 时只跑第一段精确 `Rect.contains`、**跳过**第二段裙边兜底容差，字形外一律返回 -1。默认 false，查词/悬停命中语义完全不变。
  - `VideoSubtitleHitTester.hitTest` / 绑定实现 `_charHitTest` / `_hitEntryIndexAt` 透传 `exactOnly`。
  - `_onDismissBarrierTap` 改 `_subtitleHitTester.hitTest(globalPos, exactOnly: true)`：点字幕行周围空白 halo → 命中为空 → 落到 `_popNestedPopupAt(0)` 关整栈 + 恢复播放（`shouldResumeAfterLookupDismiss`）；点在字形上仍切词（TODO-758 不回归）；嵌套门控 `shouldSwitchWordOnBarrierTap`（BUG-410）不动；查词胖手指容差（TODO-971）不动。恢复了 BUG-410 备注承诺的「落纯空白正常」。
  - hover 换词（`_onDismissBarrierHover`）、Shift 查词（`_triggerShiftLookupAtLastPointer`）仍走宽容差（查词意图）。
  - **补（用户复诉「半个屏幕远也重查」）**：截图证据——第二次查到的是 **市川(いちかわ)**，画面字幕里根本没有，只在**右侧字幕列表面板**里。`_onDismissBarrierTap` 在底部字幕 miss 后**兜底反查字幕列表** `_subtitleListHitTester`（BUG-874），用的也是宽容差（`subtitleListCharHitFromParagraph` 的半字格裙边）。列表面板占右半屏 = 「半个屏幕远」。点列表想关闭 → 被兜底吃成「切列表里的词」反复重查。故给 `subtitleListCharHitFromParagraph` / `_hitTestRows` / `VideoSubtitleListHitTester.hitTest` 同加 `exactOnly`，barrier 列表兜底也用 `exactOnly: true`——点列表**字形盒外**的行距/边距空白落回 dismiss。
  - **用户已确认（2026-07-19）**：规则统一为「点在字上换词、点空白关闭」，画面字幕与列表面板同款。列表面板行文本满宽、字挨字，故点列表行的**真实文字**仍切到那个列表词（用户明确接受，且**保留 BUG-874 的列表单击换词**），只有点行距/边距/字形盒外空白才关闭。即当前 exactOnly 实现，无需再移除列表兜底。
  - 提交哈希：（见分支 `worktree-bug-video-subtitle-dismiss-halo` / 本 PR）。
- **[x] ② 已加自动化测试** — 纯函数行为测试，扩展 `hibiki/test/media/video/subtitle_char_hit_tolerance_test.dart`：
  - `group('BUG-910：exactOnly ...')`：点落字形内 exactOnly 仍命中（切词保留）；字缝 / 描边 halo / 字幕行水平右缘 12px 空白在**默认宽容差命中、exactOnly 下必 -1**（对照断言两路，撤 `exactOnly` 分支即转红）。
  - 现有 8 项容差用例（TODO-916/971/BUG-825）不变，证明查词命中语义零回归。
- **备注**：barrier 真实点击坐标命中底部字幕是渲染几何产物，widget 测试照不到几何；关闭 vs 切词的判据（exactOnly 命中语义）已由纯函数在 Dart 层覆盖。最终交互（查词→点字幕行周围空白→浮层关闭+续播；点在字上→切词）留真机/模拟器焦点驱动复测一次。

## BUG-5265 · manga-audio-previous-replays-current
- **报告**：2026-11-22（应用内反馈 02uXqiI-xd，Windows，3.4.0-debug.31261：「往前一句的时候没有往前一句，而是变成重播这句了」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/manga/audio/manga_audio_playback_plan.dart` 旧 `previousLineStartMs` 的 `restartWindowMs = 1500` 音乐播放器语义）
- **[x] ① 已修复** — `previousLineStartMs` 改为始终跳到「当前句」（与高亮同源的 `currentLineItemIndex`）的前一句；驱动 `_displayLineAt` 改用同一个判定
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/audio/manga_audio_playback_test.dart`：「上一句始终到正高亮那句的前一句…」（句中 >1.5 秒、句后停顿 / 页尾补齐、页停留、页首 lead、首句）、「连按上一句：跳转在途时第二下接着往前一句」，并改正原「上一句 / 下一句」用例里钉住旧语义的断言
- **备注**：有声书同一操作早在 BUG-3791 去掉了这种语义，漫画有声与之不一致。重播当前句仍走驱动的 `playFromLine(null)`（查词后重播用它）。

### 根因

漫画有声成品的「上一句」（播放条按钮、`skipLine(-1)` 即快捷键 / 媒体键都走
`MangaAudioPlaybackDriver.previous()` → `plan.previousLineStartMs`）带 1.5 秒「先回句首」
窗口：当前句已播超过 1.5 秒就返回本句句首，只有句首 1.5 秒内再按才到上一句。

更糟的是参照句的求法：往回找「此前最近一句」，所以停在句后停顿 / 页尾补齐里（此时
`ms - 本句句首` 必然大于本句时长，几乎总超过 1.5 秒）按，都只会回到刚读完那句的句首
——而阅读器此刻高亮的正是这句，用户看到的就是「重播这句」。

### 修复

- 抽出 `MangaAudioPlaybackPlan.currentLineItemIndex(index)`：某条目上的「当前句」（句子条目
  是它自己；句间停顿 / 页尾补齐算本页刚读完那句；页首 lead 算本页第一句；无台词页为
  null）。驱动显示高亮（`_displayLineAt`）与「上一句」都用它，按钮跳到的永远是屏幕上
  正框着那句的前一句。
- `previousLineStartMs` 去掉 `restartWindowMs`：跳到当前句的前一句句首；页停留（无高亮）
  里按回到此前最近读过的那句；已是首句回到 0。
- 连按：`previous()` 以 `positionMs`（含在途跳转目标）为参照，第二下自然再往前一句。

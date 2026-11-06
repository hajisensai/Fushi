## BUG-4213 · 波浪进度条点按不跳转（按住超过 100ms 的点按被横向拖动的 cancel 清掉）
- **报告**：2026-11-04（用户：应用内反馈 #358s4Ae_fn，Android 荣耀 ELI-AN00 369x820，3.3.0-debug.23315：音乐模块进度条只能拖、点按没反应）
- **真实性**：✅ 真 bug（widget 测试复现）。音乐模块可点的进度条只有一条：播放 / 歌词页 `_buildSeek` 的 `FushiWavySeekBar`（窄屏 / 唱片 / 宽屏 dock 四个布局共用）；迷你播放条只有圆环进度不可点，MV 页是标准 `FushiSlider`。`FushiWavySeekBar` 的点按与横向拖动共用一份 `_dragFraction`：手指按住超过 kPressTimeout（100ms，真机点按很常见）时 onTapDown 先触发 `_beginDrag`，随后抬起、竞技场把横向拖动判输，DragGestureRecognizer 调 `onHorizontalDragCancel` → `_endDrag(commit: false)`（`fushi/lib/src/utils/components/fushi_m3e_player.dart:867`）把点按的状态清空，接着到来的 onTapUp 无事可提交，不 seek。瞬时点按（测试 `tapAt`、桌面鼠标快速点击）里 onTapDown 在判输之后才触发，所以旧测试一直绿、上次静态分析没找到。同一组件也用于有声书歌词模式、视频遥控、桌面视频平板面板，一并受影响。
- **[x] ① 已修复** — 记下当前这段按下 / 拖动的发起方（`_SeekGesture.tap` / `.drag`），`_endDrag` 只收尾自己开的那段，拖动更新也只认拖动发起的段。提交 `c4024721b5`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_wavy_seek_bar_hit_fraction_test.dart`「按住超过 kPressTimeout 再松手也提交 seek」（修前实测 `Actual: []`）；`fushi/test/pages/music_lyrics_page_test.dart` 真歌词页窄屏 369x820@3.25 + Android touch slop 8dp：瞬时点按、按住 300ms 再松手（修前只记到第一次 seek）、带 10dp 抖动的点按都提交 seek。
- **备注**：未在荣耀真机复测（无设备）；反馈无日志，「是哪个进度条」以代码盘点为准。

## BUG-1763 · 视频字幕字数暂停拖进度条也计无播放停留判据
- **报告**：2026-08-21（统计「到达即计」专项排查，随 BUG-1761 同批；产品决策：
  到达≠看过，漫画/书籍/视频同规则）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_watch_tracker.dart` 旧
  `_onSourceChanged`：只要 `currentCueIndex >= 0` 且未进过去重集就**立刻全额**计入
  该句字数——不看 `isPlaying`、不看播了多久。cue 下标由 125ms 定时器 +
  `seekMs` 即时同步驱动（都不看播放态），于是：暂停态拖进度条每个落点命中的句子
  全额入账；字幕列表点击/上一句下一句连按每点一句；开视频落在续播断点 cue 上还没
  按播放就已计一句。「0 分钟观看 + 几千字幕字」可以纯靠暂停拖条刷出来。观看时长
  有 `isPlaying` + `isContinuousWatchGap` 双门，字幕字数一个门都没有——两条统计
  路的门严重不对齐。
- **[x] ① 已修复** — 停留门（媒体时间，不用墙钟——倍速/暂停/后台冻结下墙钟都会
  歪）：`_onSourceChanged` 改为「候选观察窗」——换句时先按已观察的**真实播放推进
  量**结算旧候选（纯谓词 `shouldCountCueDwell`，门槛 `min(kCueDwellMs=1500,
  cue 自身时长)`——日语字幕大量 cue 短于 1.5s，固定阈值会让它们永远不计）；同句
  时只有 `isPlaying` 态的位置前进才累计，单次观察封顶 1000ms（cue 内 seek 跳变不
  算停留），达标立即入账。暂停/seek 只移动观察基线不累计。`onEpisodeChanged`
  一并清候选（下标指向旧集 cue 表）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_watch_tracker_test.dart`
  「dwell gate + monotonic dedup」组重写为模拟真实播放推进：真实停留才计/回看不
  重复、暂停拖条落点不计、播放中快速掠过不计、短 cue 以自身时长为门、cue 内
  seek 跳变封顶不计 五条行为用例 + `shouldCountCueDwell` 纯谓词三条。
- **备注**：与 BUG-1761（漫画停留门）、BUG-1762（EPUB 到达即计+跳转水位洞）同批
  产品规则。观看时长路径未动（原有双门正确）。

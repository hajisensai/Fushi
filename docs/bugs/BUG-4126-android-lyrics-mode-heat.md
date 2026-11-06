## BUG-4126 · Android 有声书歌词模式发热：被歌词覆盖层盖住的阅读器层仍按 vsync 请帧，每帧拖着 Hybrid Composition 全屏 overlay 合成
- **报告**：2026-11-05（用户：小米平板 5 nabu，120 Hz，歌词模式播放时明显发热）
- **真实性**：✅ 真 bug。真入口 profile APK（生产 `WidgetsFlutterBinding` + `app.main()`，只加请帧计数）实测：歌词模式播放中 Flutter 约 20～27 帧/秒、HWUI 87～99 帧/秒、GPU 42～47%、主线程 58～61%、GC 线程 45～50%；暂停时 Flutter 1 帧/秒、GPU 4%。请帧调用栈 4 s 采样：`Ticker._tick` 190 次几乎全部来自**被歌词覆盖层盖住的迷你播放条**的波浪进度条——
  - `fushi/lib/src/media/audiobook/audiobook_play_bar.dart:772`（base `df8bddcd161`）`FushiWavyLinearProgress(waving: c.isPlaying)`，其 `_RepeatingTicker`（`fushi/lib/src/utils/components/fushi_expressive_progress.dart:83-93`）播放中每个 vsync 都推进；
  - `audiobook_play_bar.dart:544` 迷你条 500 ms `Timer.periodic` setState 不看 `TickerMode`；
  - `fushi/lib/src/reader/reader_status_footer.dart:436` / `:670` 状态栏秒表计时器同样不看 `TickerMode`。
  这些控件在 `reader_fushi_page.dart:4329-4442` 的阅读器 Stack 里，歌词覆盖层盖在上面后用户看不见，却仍每帧重绘。Android 上阅读器 WebView 走 Hybrid Composition，任一帧都要把 1600×2560 的 overlay（`FlutterImageView` / `ImageReader`）重新合成：ART 采样主线程约 23% 在 `FlutterImageView.onDraw` / `updateCurrentBitmap`，`Bitmap.wrapHardwareBuffer` 每帧分配造成 GC 线程常驻。被盖住层的无效请帧是其中可确认、可消除的一份；修后复测 HWUI 帧率基本不变，说明它不是全部热源（见下表与「后续」）。
- **[x] ① 已修复（部分降热）** — 歌词覆盖层在场时，被盖住的整个阅读器层（正文、翻页卷曲、章节转场、顶部进度、桌面页眉、进度边条、状态栏、悬浮球、底栏 chrome）统一包进一个 `TickerMode(enabled: !_lyricsOverlayShown)`（`lyrics.part.dart` 的 `_lyricsOverlayShown` / `_coveredByLyricsOverlay`，判据只写一次，覆盖层 / 词典 / ready 标记不在里面）；迷你条 `_syncTicker` 与状态栏秒表（新 mixin `_TrackerTickRefresh`）在 `didChangeDependencies` 跟随 `TickerMode.valuesOf(context).enabled` 起停计时器，恢复时当帧按现值重画。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_mini_player_ticker_mode_test.dart`（盖住 + 播放中：3 s 内不请帧、无 transient callback、进度不重建；恢复帧立即显示现值、波浪恢复、计时器恢复；去掉 `&& _tickerModeEnabled` 变异即红）；`fushi/test/reader/reader_status_footer_test.dart` 新增同类用例；`reader_lyrics_webview_reuse_guard_static_test.dart` 字面随判据更新。
- **备注**：前后对照见下表（真入口 profile APK，单章 fixture，静音音频）。未采纳方案「歌词模式隐藏正文 WebView」：实测 hidereader 阶段 Flutter/HWUI/GPU 几乎不降（19.9 fps / 82 / 48%），且正文 WebView 承担跨章恢复链（rAF 驱动、只 `reader_pagination_scripts.dart:1103` 有 `document.hidden` 回退，BUG-3798 守卫），隐藏会让出歌词模式后的跨章恢复位置失效，风险大于收益。
  - 未改（不在被盖住的阅读器层，列出待评估）：`reader_audiobook_panel.dart:164`、`reader_statistics_sheet.dart`、`reader_quick_settings_sheet.dart`、`fushi_m3e_overlays.dart`、`lyrics_player_apple.dart`、`lyrics_player_modern_shared.dart` 的周期计时器；`audiobookshelf_progress_sync.dart` 与 `navigation.part.dart` 10 s 进度轮询是数据轮询，保留。

### 前后对照（小米平板 5，真入口 profile APK，每阶段稳定 8 s 后量 30 s）

| 组 | 阶段 | Flutter 帧/s | 请帧 begin/s | HWUI 帧/s | GPU busy | RenderThread | 主线程 | GC（HeapTaskDaemon） | GPU 温度（相对暂停） |
|---|---|---|---|---|---|---|---|---|---|
| 有硬件层 · 修前 | base / base2 | 20.5～20.8 / 26.9 | 26.8 | 83 / 99 | 43% / 47% | 36% / 41% | 51～61% | 35～50% | +13.5 °C |
| 有硬件层 · 修后 | base / base2 | 13.0 / 14.6 | 15.0 / 16.3 | 83 / 90 | 38% / 42% | 32% | 57% | 40% | +9.7 °C |
| 无硬件层 · 修前 | base / base2 | 15.0～17.2 / 17.9 | — | 57～75 / 75 | 38～42% | 37% | 57% | 65% | +8.9 °C |
| 无硬件层 · 修后 | base / base2 | 11.4 / 13.0 | — | 63 / 73 | 36% / 39% | 31～37% | 48～50% | 33～38% | +8.5 °C |
| 两组暂停 | paused | 1.0 | — | 3 | 3～7% | 1～2% | 29% | 8% | — |

- 修后请帧栈里 `Ticker._tick`（迷你条波浪）从 190 次 / 4 s 降为 0；剩余请帧主要是歌词覆盖层自己的 M3E 播放卡 `_ThrottledFrameDriver`（可见层，按设计照常动）和 1 Hz 的统计 / 时钟轮询。
- **HWUI 帧率与 GPU 占用基本没降**（83～99 → 83～90 帧/s，GPU 降 4～5 个百分点）：Android 视图树的帧主要不是 Flutter 帧驱动的，剩余热量来自歌词 WebView / HC 合成本身，不在本修复范围，作为后续调查项。
- 电流读数（`current_now`）受 USB 充电状态主导（暂停时修前 +360 mA、修后 −93 mA），不能作为对照，未列入。温升起点不同（修前机身更热），只当弱证据。

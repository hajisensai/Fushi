/// activity_events 表（schema v49）的字符串值域常量。
///
/// 落 DB 的 `event_type` / `media_type` 取这些值。定义在 hibiki_core 是因为它们是
/// **schema 的值域一部分**，且写入点散落在多个 package/层（阅读器页、视频页、EPUB
/// 导入器、视频仓库），统一在核心层定义避免各层重复字面量或跨层 import UI。
library;

/// event_type：一次阅读 session 结束。
const String kActivityRead = 'read';

/// event_type：一次观看 session 结束。
const String kActivityWatch = 'watch';

/// event_type：导入了一本书 / 一个视频。
const String kActivityAdded = 'added';

/// event_type：游戏游玩。两个写入方：`GalgamePlayTracker` 写会话时长
/// （`durationMs`，前台窗口计时，时长真相源），`GalHookSessionController` 写 hook
/// 文本字符数（`charsDelta`，不带时长，防双计）。
const String kActivityGame = 'game';

/// media_type：书（EPUB / 字幕书 / 有声书）。
const String kActivityMediaBook = 'book';

/// media_type：视频。
const String kActivityMediaVideo = 'video';

/// media_type：游戏（galgame 游玩会话与 hook 文本活动）。
const String kActivityMediaGame = 'game';

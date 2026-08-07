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

/// 活动事件 media_type 的**内存态**枚举（命名统一 Phase 3.4，模式照
/// `SentenceSourceKind` / `MediaKind`）。落库仍存上面的 `kActivityMedia*`
/// 原字符串（字节不变），本枚举供读取侧显式解析 / 穷尽 switch。
///
/// ⚠️ 与合集/书架域（`MediaKind`）**互不通用**：`book` ≠ `epub`（本域的
/// `book` 折叠了 EPUB 与字幕书两个书架种类）；跨域换算走
/// `media_kind_mappings.dart` 的显式映射，不得手写。
enum ActivityMediaKind {
  /// 书（EPUB / 字幕书 / 有声书；mediaKey=bookKey，无书架种类标记）。
  book(kActivityMediaBook),

  /// 视频（mediaKey=bookUid）。
  video(kActivityMediaVideo),

  /// 游戏（mediaKey=galgames.id）。
  game(kActivityMediaGame);

  const ActivityMediaKind(this.dbValue);

  /// 落 DB 的字符串（与 `kActivityMedia*` 常量逐字节一致）。永不改变；
  /// 持久化场景只用本字段，绝不用 `.name`。
  final String dbValue;

  /// 严格解析：精确匹配三个落库值之一，未知 / null → null，绝不抛。
  static ActivityMediaKind? tryParse(String? raw) {
    for (final ActivityMediaKind kind in ActivityMediaKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}

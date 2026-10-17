/// 媒体种类值域间的**显式跨域映射表**（命名统一 Phase 3.4）。
///
/// 本仓有多套互不通用的媒体种类字符串值域（合集/书架 [MediaKind]、活动事件
/// [ActivityMediaKind]、统计来源 [StatSourceKind]、Profile 绑定
/// `ProfileMediaKind`、sync 墓碑 `SyncTombstoneKind`……）。值域**不合并**
/// （`book` ≠ `epub` 是真实语义差），跨域换算此前散在 UI 层隐式手写
/// （如 home_dashboard 对 book 活动行「epub 优先、srt 回退」的复合键推导）。
/// 本文件把这些换算收口成穷尽 switch 的纯函数——加媒体种类时编译器强制
/// 补齐每张映射，守卫测试钉死既有映射对。
///
/// 刻意**不提供** `MediaKind → ProfileMediaKind` 映射：Profile 绑定域的
/// `audiobook` / `lyrics` / `srtbook` 取决于运行时挂载状态（同一本
/// [MediaKind.epub] 书可解析到三种绑定），不是静态种类换算，见
/// profile_media_kind.dart 文件头。
library;

import 'activity_event_types.dart';
import 'media_kind.dart';
import 'stat_source_kind.dart';
import 'tag_host_kind.dart';

/// 合集/书架种类 → 活动事件种类（epub / srt 都折叠进活动域的 `book`）。
ActivityMediaKind activityMediaKindOf(MediaKind kind) => switch (kind) {
      MediaKind.epub || MediaKind.srt => ActivityMediaKind.book,
      MediaKind.video => ActivityMediaKind.video,
      MediaKind.game => ActivityMediaKind.game,
    };

/// 活动事件种类 → 其可能对应的合集/书架种类（**有序**：book 活动行的
/// mediaKey 不带书架种类标记，按「epub 优先、srt 回退」逐一试探——与
/// home_dashboard 时间轴合集归属推导的既有语义一致）。
List<MediaKind> shelfKindsOfActivityMedia(ActivityMediaKind kind) =>
    switch (kind) {
      ActivityMediaKind.book => const <MediaKind>[
          MediaKind.epub,
          MediaKind.srt
        ],
      ActivityMediaKind.video => const <MediaKind>[MediaKind.video],
      ActivityMediaKind.game => const <MediaKind>[MediaKind.game],
    };

/// 合集/书架种类 → 统计来源种类（epub / srt 都归 `book` 桶）。
///
/// 返回类型仍可空（签名冻结）：值域将来再加 kind 时，「没有对应统计桶」必须还能
/// 表达；当前四个 kind 都有桶，故实际不返 null。game 自 [StatSourceKind.game]
/// 起有了自己的桶——此前返 null 是因为统计域只有 book / video 两桶。
StatSourceKind? statSourceKindOf(MediaKind kind) => switch (kind) {
      MediaKind.epub || MediaKind.srt => StatSourceKind.book,
      MediaKind.video => StatSourceKind.video,
      MediaKind.game => StatSourceKind.game,
    };

/// 标签宿主种类 → 标签墓碑域（[BookTagMembershipTombstones].mediaType 的落库值）。
///
/// 五个宿主种类都进互联标签同步、都有墓碑语义（tag_sync_engine）。epub / srt /
/// video / game 与 [MediaKind] 同串同义（旧行零迁移）；合集不是媒体、[MediaKind]
/// 里没有它，墓碑域直接取 [TagHostKind.collection] 的落库值 `'collection'`。
/// 穷尽 switch：以后加宿主种类编译期就逼着在这里定墓碑域，不会静默写错域（写错
/// 域的墓碑所有读取端都命不中，跨端标签移除会静默失传，review5-9）。
String tagTombstoneDomainOf(TagHostKind kind) => switch (kind) {
      TagHostKind.epub => MediaKind.epub.dbValue,
      TagHostKind.srt => MediaKind.srt.dbValue,
      TagHostKind.video => MediaKind.video.dbValue,
      TagHostKind.game => MediaKind.game.dbValue,
      TagHostKind.collection => TagHostKind.collection.dbValue,
    };

/// 合集所属的**库页域**（书架 / 漫画库 / 视频库 / 游戏库）。合集表本身不带种类列
/// （同一张 `media_collections` 承载全部库页），一个合集属于哪个库页由它的成员
/// 推导：任一成员落在某域，该合集就在那个域的「加入合集」列表里出现（BUG-2974）。
enum CollectionShelfDomain { books, manga, video, games }

/// 合集/书架种类 → 库页域。[MediaKind.epub] 同时承载书与漫画（`epub_books.format`
/// 为 `manga` 的行住漫画库），由调用方按格式给出 [isManga]；其它种类忽略它。
CollectionShelfDomain collectionShelfDomainOf(
  MediaKind kind, {
  bool isManga = false,
}) =>
    switch (kind) {
      MediaKind.epub =>
        isManga ? CollectionShelfDomain.manga : CollectionShelfDomain.books,
      MediaKind.srt => CollectionShelfDomain.books,
      MediaKind.video => CollectionShelfDomain.video,
      MediaKind.game => CollectionShelfDomain.games,
    };

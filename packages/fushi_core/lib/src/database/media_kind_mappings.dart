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

/// 合集/书架种类 → 统计来源种类（epub / srt 都归 `book` 桶；游戏不入
/// book / video 统计 → null）。
StatSourceKind? statSourceKindOf(MediaKind kind) => switch (kind) {
      MediaKind.epub || MediaKind.srt => StatSourceKind.book,
      MediaKind.video => StatSourceKind.video,
      MediaKind.game => null,
    };

/// 标签宿主种类 → 标签墓碑域（[BookTagMembershipTombstones].mediaType 的值域，
/// 复用 [MediaKind]）。只有 epub/video 进 tag live-sync、有墓碑语义；其余
/// kind 调到这里是调用方 bug——扔 ArgumentError 而不是静默写错域（写错域的
/// 墓碑所有读取端都命不中，跨端标签移除会静默失传，review5-9）。
MediaKind tombstoneMediaKindOf(TagHostKind kind) => switch (kind) {
      TagHostKind.epub => MediaKind.epub,
      TagHostKind.video => MediaKind.video,
      TagHostKind.srt ||
      TagHostKind.collection ||
      TagHostKind.game =>
        throw ArgumentError.value(kind, 'kind', '该 kind 不进 tag sync，无墓碑域'),
    };

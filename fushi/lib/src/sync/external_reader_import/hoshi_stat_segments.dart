import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

/// 导入段的 `device_id`。固定常量而不是本机设备 id：会话流按
/// `(deviceId, mediaKind, mediaKey)` 相邻 ≤30 分钟归并（`deriveStudySessions`），
/// 用独立 id 保证导入的历史永远不会和本机真实会话粘成一条。
const String kExternalReaderImportDeviceId = 'import:hoshi';

/// uid 种子的版本前缀。改切片 / 锚点算法时升版本，否则新旧两版切出的片会以
/// 不同 uid 并存、同一段阅读被计两次。
const String _kUidSeedPrefix = 'fushi-import/v1|hoshi';

/// 日记录时长上限：一天的统计不可能超过 24 小时，超过即数据损坏。
const int _kMaxDailySpanMs = Duration.millisecondsPerDay;

/// 会话墙钟跨度比有效阅读时长多出这么多时，视为「开着阅读器挂机」：不再按墙钟
/// 摊，而是把阅读时长从 `startedAt` 起连续排（Hoshi 自己也只按 `startedAt` 归日），
/// 免得几十分钟的阅读被摊薄到好几天的小时格里。
const int _kMaxSessionIdleGapMs = Duration.millisecondsPerHour;

/// 导入段落到哪本书、哪个 Profile 下。
class ExternalReaderSegmentTarget {
  const ExternalReaderSegmentTarget({
    required this.mediaKey,
    required this.title,
    required this.format,
    required this.profileId,
    required this.profileName,
  });

  /// Fushi 的 bookKey（`sanitizeTtuFilename(title)`）。
  final String mediaKey;

  /// 段上的标题快照（书在库时取库里的标题，否则取 Hoshi 的书名）。
  final String title;

  /// `BookFormat.dbValue`（通常是 `'epub'`）。
  final String format;
  final int profileId;

  /// 进 uid 种子：同一份备份导进两个 Profile 时两边各有一份，而不是主键相撞、
  /// 第二个 Profile 什么都拿不到。
  final String profileName;
}

/// 一段落在单个本地整点小时之内的阅读片。
class ExternalReaderSegmentPiece {
  const ExternalReaderSegmentPiece({
    required this.startAt,
    required this.endAt,
    required this.durationMs,
    required this.chars,
  });

  final int startAt;
  final int endAt;
  final int durationMs;
  final int chars;
}

/// 把 `[startAt, endAt)` 这段阅读按**本地整点**切片（`study_segments` 的不变式：
/// 段不跨小时，`hour` 列才精确）。时长按每片墙钟重叠比例分摊、字数按时长比例分摊
/// （时长为 0 时按墙钟），都用累计取整，末片自然吃掉余数、总和精确不漂。
///
/// 调用方保证 `endAt - startAt >= durationMs`，于是每片 `durationMs` 恒不超过
/// 该片墙钟跨度（累计 floor：`floor(D·c_i/S) - floor(D·c_{i-1}/S) <= ceil(D·s_i/S)
/// <= s_i`）。零跨度（纯字数）返回一片零宽段。
List<ExternalReaderSegmentPiece> splitReadingSpanByLocalHour({
  required int startAt,
  required int endAt,
  required int durationMs,
  required int chars,
}) {
  assert(endAt - startAt >= durationMs);
  final int span = endAt - startAt;
  if (span <= 0) {
    return <ExternalReaderSegmentPiece>[
      ExternalReaderSegmentPiece(
        startAt: startAt,
        endAt: startAt,
        durationMs: 0,
        chars: chars,
      ),
    ];
  }
  final List<(int, int)> windows = <(int, int)>[];
  int cursor = startAt;
  while (cursor < endAt) {
    final DateTime local = DateTime.fromMillisecondsSinceEpoch(cursor);
    final int nextHour = DateTime(
      local.year,
      local.month,
      local.day,
      local.hour + 1,
    ).millisecondsSinceEpoch;
    final int pieceEnd = nextHour < endAt ? nextHour : endAt;
    windows.add((cursor, pieceEnd));
    cursor = pieceEnd;
  }

  final List<int> durations = _distribute(
    total: durationMs,
    weights: <int>[for (final (int a, int b) in windows) b - a],
  );
  final List<int> charShares = _distribute(
    total: chars,
    weights: durationMs > 0
        ? durations
        : <int>[for (final (int a, int b) in windows) b - a],
  );
  return <ExternalReaderSegmentPiece>[
    for (int i = 0; i < windows.length; i++)
      ExternalReaderSegmentPiece(
        startAt: windows[i].$1,
        endAt: windows[i].$2,
        durationMs: durations[i],
        chars: charShares[i],
      ),
  ];
}

/// 累计 floor 分摊：第 i 份 = floor(total·W_i/W) − floor(total·W_{i−1}/W)，
/// 总和恰为 [total]。权重全 0 时整份给最后一片。
List<int> _distribute({required int total, required List<int> weights}) {
  final int weightSum = weights.fold(0, (int a, int b) => a + b);
  if (weightSum <= 0) {
    return <int>[
      for (int i = 0; i < weights.length; i++)
        i == weights.length - 1 ? total : 0,
    ];
  }
  final List<int> shares = <int>[];
  int cumulativeWeight = 0;
  int previous = 0;
  for (final int w in weights) {
    cumulativeWeight += w;
    final int upTo = (total * cumulativeWeight) ~/ weightSum;
    shares.add(upTo - previous);
    previous = upTo;
  }
  return shares;
}

/// 32 位 hex（sha256 前 128 bit），与 `FushiDatabase.newStudySegmentUid` 同形。
/// 种子可重算 = 重复导入同一份备份是同一批 uid（配合 LWW 即 no-op）。
String externalReaderSegmentUid(String seed) =>
    sha256.convert(utf8.encode(seed)).toString().substring(0, 32);

/// iOS 会话 → 段。会话一律按 Fushi 的日界（`statDateKeyOf`）重新定 dateKey：
/// 会话带的是真实起止时刻，与 Fushi 自己写的段同一口径。
List<StudySegmentsCompanion> studySegmentsForSession(
  ExternalReaderSession session,
  ExternalReaderSegmentTarget target,
) {
  final int rawDuration = (session.readingTimeSec * 1000).round();
  final int durationMs = rawDuration < 0 ? 0 : rawDuration;
  final int chars = session.charactersRead < 0 ? 0 : session.charactersRead;
  if (durationMs == 0 && chars == 0) return const <StudySegmentsCompanion>[];

  final int startAt = session.startedAt;
  int endAt = session.endedAt < startAt + durationMs
      ? startAt + durationMs
      : session.endedAt;
  if (endAt - startAt > durationMs + _kMaxSessionIdleGapMs) {
    endAt = startAt + durationMs;
  }
  final int updatedAt = session.modifiedAt > 0 ? session.modifiedAt : endAt;
  final List<ExternalReaderSegmentPiece> pieces = splitReadingSpanByLocalHour(
    startAt: startAt,
    endAt: endAt,
    durationMs: durationMs,
    chars: chars,
  );
  return <StudySegmentsCompanion>[
    for (int i = 0; i < pieces.length; i++)
      _companion(
        uid: externalReaderSegmentUid(
          '$_kUidSeedPrefix|${target.profileName}|session|${session.id}|$i',
        ),
        piece: pieces[i],
        dateKey: FushiDatabase.statDateKeyOf(
          DateTime.fromMillisecondsSinceEpoch(pieces[i].startAt),
        ),
        updatedAt: updatedAt,
        target: target,
      ),
  ];
}

/// ッツ日记录的时间锚：日记录只有「哪天、读了多久」，没有起止时刻。
///
/// 先信 `lastStatisticModified`（= 当天最后一次写统计的时刻，通常就是那天最后
/// 一次合书）：`end = min(它, now)`、`start = end − 时长`，只要整段落在
/// `[D 00:00, D+2 00:00]` 内就用（容纳 Hoshi 最多 24 小时的日界偏移）。否则退到
/// 当天 Fushi 日界整点起排（`statDayResetHour`）。
({int startAt, int endAt}) anchorDailyRecord(
  TtuStatistics record, {
  required int durationMs,
  required int nowMs,
}) {
  final List<String> parts = record.dateKey.split('-');
  final int year = int.parse(parts[0]);
  final int month = int.parse(parts[1]);
  final int day = int.parse(parts[2]);
  final int windowStart = DateTime(year, month, day).millisecondsSinceEpoch;
  final int windowEnd = DateTime(year, month, day + 2).millisecondsSinceEpoch;
  if (record.lastStatisticModified > 0) {
    final int end = record.lastStatisticModified < nowMs
        ? record.lastStatisticModified
        : nowMs;
    final int start = end - durationMs;
    if (start >= windowStart && end <= windowEnd) {
      return (startAt: start, endAt: end);
    }
  }
  int start = DateTime(
    year,
    month,
    day,
    FushiDatabase.statDayResetHour,
  ).millisecondsSinceEpoch;
  int end = start + durationMs;
  if (end > nowMs) {
    // 当天的记录又缺 lastStatisticModified：不能把阅读排到「未来」（活动流 /
    // 书架「最近阅读」按 endAt 排）。
    end = nowMs;
    start = end - durationMs;
  }
  return (startAt: start, endAt: end);
}

/// ッツ日记录（Android / 旧 iOS）→ 段。dateKey **原样保留**：Hoshi 写入时已按它
/// 自己的日界换算过，读取面按 dateKey 做 key 算术、不重新分桶，这样导入后每天的
/// 总量与 Hoshi 里看到的完全一致。
///
/// [sourceTitle] 是这条记录所属书在 Hoshi 里的书名（进 uid 种子；不用 Fushi 的
/// bookKey——不同设备上同一本书的 bookKey 可能带 ` (2)` 后缀）。
List<StudySegmentsCompanion> studySegmentsForDailyRecord(
  TtuStatistics record, {
  required String sourceTitle,
  required ExternalReaderSegmentTarget target,
  required int nowMs,
}) {
  final int rawDuration = (record.readingTimeSec * 1000).round();
  final int durationMs = rawDuration < 0
      ? 0
      : (rawDuration > _kMaxDailySpanMs ? _kMaxDailySpanMs : rawDuration);
  final int chars = record.charactersRead < 0 ? 0 : record.charactersRead;
  if (durationMs == 0 && chars == 0) return const <StudySegmentsCompanion>[];

  final ({int startAt, int endAt}) anchor = anchorDailyRecord(
    record,
    durationMs: durationMs,
    nowMs: nowMs,
  );
  final int updatedAt = record.lastStatisticModified > 0
      ? record.lastStatisticModified
      : anchor.endAt;
  final List<ExternalReaderSegmentPiece> pieces = splitReadingSpanByLocalHour(
    startAt: anchor.startAt,
    endAt: anchor.endAt,
    durationMs: durationMs,
    chars: chars,
  );
  return <StudySegmentsCompanion>[
    for (int i = 0; i < pieces.length; i++)
      _companion(
        uid: externalReaderSegmentUid(
          '$_kUidSeedPrefix|${target.profileName}|day|$sourceTitle|'
          '${record.dateKey}|$i',
        ),
        piece: pieces[i],
        dateKey: record.dateKey,
        updatedAt: updatedAt,
        target: target,
      ),
  ];
}

StudySegmentsCompanion _companion({
  required String uid,
  required ExternalReaderSegmentPiece piece,
  required String dateKey,
  required int updatedAt,
  required ExternalReaderSegmentTarget target,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: kExternalReaderImportDeviceId,
  mediaKind: kActivityMediaBook,
  mediaKey: target.mediaKey,
  format: Value(target.format),
  title: target.title,
  startAt: piece.startAt,
  endAt: piece.endAt,
  dateKey: dateKey,
  hour: DateTime.fromMillisecondsSinceEpoch(piece.startAt).hour,
  durationMs: Value(piece.durationMs),
  chars: Value(piece.chars),
  updatedAt: updatedAt,
  profileId: Value(target.profileId),
);

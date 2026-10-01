/// 「这部作品为什么没刮出身份」在刮削运行记录里的落地形态。
///
/// 运行记录（`video_source_scrape_runs.summary_json`）只有 warnings/errors 两个
/// 自由文本清单，不为此加 DB 列：与 `ai:matched`（见
/// `video_scrape_ai_identity.dart`）同一条切法，用固定前缀 `pending:` 把原因码、
/// AI 结果、候选数与作品键编进 message，UI 侧再用 [parseVideoScrapePendingNote]
/// 还原成本地化文案。原有的人类可读文案整段放在 `reason=` 里，靠子串匹配的
/// 日志 / 测试不受影响。
///
/// 之前只落一段「匹配结果存在歧义，需要人工确认：<英文 reason>」，事后既分不出
/// 是哪个分支挂起的，也看不出 AI 有没有被问过、问了是什么结果（BUG-2828）。
library;

/// 标记前缀。整条 message 形如
/// `pending:awaiting_confirmation ai=declined candidates=2 key=book%3A1 reason=…`。
const String kVideoScrapePendingNotePrefix = 'pending:';

/// 作品停在「没有身份」的原因。[wire] 是落库值，改枚举名不能改它。
enum VideoScrapePendingCause {
  /// 成员的 AniDB 文件哈希分属不同作品，又没法自动拆开。
  hashConflict('hash_conflict'),

  /// 资料源给出了候选，但没有一个能换成可直拉的身份。
  noUsableCandidate('no_usable_candidate'),

  /// 多个 / 需复核的候选，AI 没收敛，且这一趟没有人工确认回调（后台补刮）。
  awaitingConfirmation('awaiting_confirmation'),

  /// 弹给用户确认，用户取消了。
  dismissed('dismissed'),

  /// 标题、类型、年份或季号都没通过严格校验。
  notFound('not_found'),

  /// 资料源不可用（网络 / 凭据 / 限流）。
  providerUnavailable('provider_unavailable');

  const VideoScrapePendingCause(this.wire);

  final String wire;

  static VideoScrapePendingCause? fromWire(String value) {
    for (final VideoScrapePendingCause cause in values) {
      if (cause.wire == value) return cause;
    }
    return null;
  }
}

/// 这部作品挂起时 AI 身份消解的结果。
enum VideoScrapeAiOutcome {
  /// 这条分支走不到 AI（哈希冲突、查无、源不可用、候选不可用）。
  notAsked('not_asked'),

  /// 没有装配 AI 决策器（无头服务端等）。
  unavailable('unavailable'),

  /// 「视频作品识别」没有指派可用的 AI 提供商。
  unassigned('unassigned'),

  /// AI 调用失败（本趟余下作品也不再问）。
  failed('failed'),

  /// AI 认为没有候选成立，或置信度不到自动采用门槛。
  declined('declined'),

  /// AI 采用了一个候选（作品随即被认出，不会出现在挂起标记里）。
  accepted('accepted');

  const VideoScrapeAiOutcome(this.wire);

  final String wire;

  static VideoScrapeAiOutcome? fromWire(String value) {
    for (final VideoScrapeAiOutcome outcome in values) {
      if (outcome.wire == value) return outcome;
    }
    return null;
  }
}

/// 已解析的挂起原因标记。
class VideoScrapePendingNote {
  const VideoScrapePendingNote({
    required this.cause,
    required this.aiOutcome,
    required this.candidateCount,
    required this.workKey,
    required this.reason,
  });

  final VideoScrapePendingCause cause;
  final VideoScrapeAiOutcome aiOutcome;
  final int candidateCount;

  /// 作品的 `VideoSourceScrapeWork.stableKey`，待确认清单按它对号。
  final String workKey;

  /// 原有的人类可读文案（含 resolver 的原始 reason）。
  final String reason;
}

final RegExp _pendingPattern = RegExp(
  '^${RegExp.escape(kVideoScrapePendingNotePrefix)}([a-z_]+) '
  r'ai=([a-z_]+) candidates=(\d+) key=(\S*)(?: reason=(.*))?$',
  dotAll: true,
);

/// 把挂起原因编码成运行记录里的一条 message。作品键可能带空格（book uid 是
/// 路径形），所以 URI 编码。
String encodeVideoScrapePendingNote(VideoScrapePendingNote note) {
  final String head = '$kVideoScrapePendingNotePrefix${note.cause.wire} '
      'ai=${note.aiOutcome.wire} '
      'candidates=${note.candidateCount} '
      'key=${Uri.encodeComponent(note.workKey)}';
  final String reason = note.reason.trim();
  return reason.isEmpty ? head : '$head reason=$reason';
}

/// 从运行记录 message 还原挂起原因；不是这种标记（旧记录 / 其它 issue）回 null。
VideoScrapePendingNote? parseVideoScrapePendingNote(String message) {
  final RegExpMatch? match = _pendingPattern.firstMatch(message.trim());
  if (match == null) return null;
  final VideoScrapePendingCause? cause =
      VideoScrapePendingCause.fromWire(match.group(1)!);
  final VideoScrapeAiOutcome? ai = VideoScrapeAiOutcome.fromWire(
    match.group(2)!,
  );
  final int? count = int.tryParse(match.group(3)!);
  if (cause == null || ai == null || count == null) return null;
  final String key;
  try {
    key = Uri.decodeComponent(match.group(4)!);
  } on ArgumentError {
    return null;
  }
  return VideoScrapePendingNote(
    cause: cause,
    aiOutcome: ai,
    candidateCount: count,
    workKey: key,
    reason: (match.group(5) ?? '').trim(),
  );
}

/// 最近的运行记录（新 → 旧）里，每个作品键第一次出现的挂起原因。
///
/// 待确认清单用它给每部作品配上「为什么还没认出来」；没有标记的作品（旧记录、
/// 从没被刮过）不在结果里，由 UI 显示「尚无刮削记录」。
Map<String, VideoScrapePendingNote> latestVideoScrapePendingNotes(
  Iterable<Iterable<String>> messagesNewestFirst,
) {
  final Map<String, VideoScrapePendingNote> notes =
      <String, VideoScrapePendingNote>{};
  for (final Iterable<String> run in messagesNewestFirst) {
    final Map<String, VideoScrapePendingNote> inRun =
        <String, VideoScrapePendingNote>{};
    for (final String message in run) {
      final VideoScrapePendingNote? note = parseVideoScrapePendingNote(message);
      if (note != null) inRun[note.workKey] = note;
    }
    for (final MapEntry<String, VideoScrapePendingNote> entry
        in inRun.entries) {
      notes.putIfAbsent(entry.key, () => entry.value);
    }
  }
  return notes;
}

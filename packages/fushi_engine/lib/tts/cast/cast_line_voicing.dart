/// 没配上音的台词：占位与补回（漫画演出稿与小说制作共用）。
///
/// 整卷 / 整本生成时某句合成失败（引擎拒收、声音不可用、重试用尽……），不让整章
/// 失败，也不悄悄跳过：
/// 1. 这句在成品里**占位**——按字数估一段静音（[estimatePlaceholderMs]），时间表、
///    页段、cue 都照常排，高亮仍走到它，其余句子不受影响；
/// 2. 账本（[CastVoicingLedger]）记下它和每次尝试（用的声音、失败码）；
/// 3. 之后**补回**：只重合成账本里的句子，可以换声音重试（候选取声音指派表的
///    `retryVoices`，跳过失败过的声音）、手动指定声音、或手动填写要念的文字，成功后
///    把占位换成真音频、从账本删掉，只重排受影响的章 / 页。
///
/// 行身份 [CastVoicingEntry.lineId] 由调用方给（漫画 `p<页>b<块…>`、小说行键），
/// 必须不随行序号变化：演出稿增删句子后序号会整体错位。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 一句占位静音的长度：按可见字符数估（试做里非 LoRA 声音的实测语速
/// `0.55 s + 0.15 s/字`），夹在 0.8–30 秒（30 秒是单条合成上限）。
int estimatePlaceholderMs(String text) {
  final int chars = text.runes.where((int r) {
    final String c = String.fromCharCode(r);
    return c.trim().isNotEmpty && !_punctuation.hasMatch(c);
  }).length;
  return (550 + 150 * chars).clamp(800, 30000);
}

final RegExp _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);

/// 一次失败的尝试。
class CastVoicingAttempt {
  const CastVoicingAttempt({
    required this.voice,
    required this.code,
    this.detail,
    required this.atMs,
  });

  /// 用的声音 id（null = 当前朗读声音）。
  final String? voice;

  /// 失败码（`TtsFailureCode.name`，或调用方自定的短码如 `voice_missing`）。
  final String code;
  final String? detail;
  final int atMs;

  Map<String, Object?> toJson() => <String, Object?>{
    if (voice != null) 'v': voice,
    'c': code,
    if (detail != null) 'd': detail,
    't': atMs,
  };

  static CastVoicingAttempt? fromJson(Object? raw) {
    if (raw is! Map || raw['c'] is! String) return null;
    final Object? v = raw['v'];
    final Object? d = raw['d'];
    final Object? t = raw['t'];
    return CastVoicingAttempt(
      voice: v is String ? v : null,
      code: raw['c'] as String,
      detail: d is String ? d : null,
      atMs: t is int ? t : 0,
    );
  }
}

/// 账本里的一句（= 成品里现在是占位静音）。
class CastVoicingEntry {
  CastVoicingEntry({
    required this.lineId,
    required this.placeholderMs,
    List<CastVoicingAttempt>? attempts,
  }) : attempts = attempts ?? <CastVoicingAttempt>[];

  final String lineId;

  /// 成品里占了多长的静音。
  int placeholderMs;

  /// 失败过的尝试，按时间先后。
  final List<CastVoicingAttempt> attempts;

  /// 失败过的声音（null 也算一种：当前朗读声音）。
  Set<String?> get failedVoices => <String?>{
    for (final CastVoicingAttempt a in attempts) a.voice,
  };

  CastVoicingAttempt? get lastAttempt =>
      attempts.isEmpty ? null : attempts.last;

  /// 「切配置重试」的下一个声音：[candidates] 里第一个没失败过、也不是 [assigned]
  /// （指派的那个已经失败了）的。没有可换的返回 null（只能手动指定或手动填写）。
  String? nextRetryVoice(String? assigned, List<String> candidates) {
    final Set<String?> failed = failedVoices;
    for (final String c in candidates) {
      if (c != assigned && !failed.contains(c)) return c;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': lineId,
    'ms': placeholderMs,
    'tries': <Object?>[for (final CastVoicingAttempt a in attempts) a.toJson()],
  };

  static CastVoicingEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    final Object? ms = raw['ms'];
    final Object? tries = raw['tries'];
    return CastVoicingEntry(
      lineId: raw['id'] as String,
      placeholderMs: ms is int && ms > 0 ? ms : 800,
      attempts: <CastVoicingAttempt>[
        if (tries is List)
          for (final Object? t in tries)
            if (CastVoicingAttempt.fromJson(t) case final CastVoicingAttempt a)
              a,
      ],
    );
  }
}

/// 一本书 / 一卷的未配音账本。
class CastVoicingLedger {
  CastVoicingLedger({Map<String, CastVoicingEntry>? entries})
    : entries = entries ?? <String, CastVoicingEntry>{};

  static const int schemaVersion = 1;

  /// 行身份 → 条目，按记账先后。
  final Map<String, CastVoicingEntry> entries;

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  bool isPlaceholder(String lineId) => entries.containsKey(lineId);

  /// 记一次失败：没有条目就新建（占位长度按 [text] 估），有就追加尝试。返回条目。
  CastVoicingEntry recordFailure({
    required String lineId,
    required String text,
    required String? voice,
    required String code,
    String? detail,
    DateTime? now,
  }) {
    final CastVoicingEntry entry = entries.putIfAbsent(
      lineId,
      () => CastVoicingEntry(
        lineId: lineId,
        placeholderMs: estimatePlaceholderMs(text),
      ),
    );
    entry.attempts.add(
      CastVoicingAttempt(
        voice: voice,
        code: code,
        detail: detail,
        atMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ),
    );
    return entry;
  }

  /// 补回成功：从账本删掉。返回它原来是不是占位。
  bool resolve(String lineId) => entries.remove(lineId) != null;

  /// 只保留 [liveIds] 里还存在的行（演出稿删句 / 重新标注后清掉孤儿条目）。
  void retainOnly(Set<String> liveIds) => entries.removeWhere(
    (String id, CastVoicingEntry _) => !liveIds.contains(id),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'lines': <Object?>[
      for (final CastVoicingEntry e in entries.values) e.toJson(),
    ],
  };

  static CastVoicingLedger fromJson(Object? raw) {
    if (raw is! Map) return CastVoicingLedger();
    final Object? lines = raw['lines'];
    return CastVoicingLedger(
      entries: <String, CastVoicingEntry>{
        if (lines is List)
          for (final Object? l in lines)
            if (CastVoicingEntry.fromJson(l) case final CastVoicingEntry e)
              e.lineId: e,
      },
    );
  }
}

/// 每本书 / 每卷一份账本：`<root>/<sha1(bookKey)>.voicing.json`（与选角表、演出稿
/// 同目录，后缀不同互不覆盖）。
class CastVoicingStore {
  CastVoicingStore(this.root);

  final Directory root;

  File fileFor(String bookKey) => File(
    p.join(root.path, '${sha1.convert(utf8.encode(bookKey))}.voicing.json'),
  );

  Future<CastVoicingLedger> load(String bookKey) async {
    final File f = fileFor(bookKey);
    if (!await f.exists()) return CastVoicingLedger();
    try {
      return CastVoicingLedger.fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return CastVoicingLedger();
    }
  }

  Future<void> save(String bookKey, CastVoicingLedger ledger) async {
    final File f = fileFor(bookKey);
    if (ledger.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(ledger.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}

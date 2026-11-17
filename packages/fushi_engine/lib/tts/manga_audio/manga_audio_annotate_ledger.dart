/// 漫画 AI 标注的失败账本：哪一页（或角色表 / 哪一场复核）没标成、试过哪些
/// 提供商 / 模型、为什么失败，以及每页被本地校验丢掉的行。
///
/// - 一页失败（网络 / 回复解析 / 全部行被校验丢弃 / 页图读不出）不让整卷失败：记进账本
///   接着标下一页；这一页之后可以「重试本页」「换一家提供商重试」（切配置重试，
///   [MangaAnnotateFailure.nextRetryProvider]），或者由用户在复核界面手工标。
/// - 模型**有意**标成「不读」的行 / 整页都不读不是失败，不进账本，也没有自动重试。
/// - 标成功后该条目从账本删除（[MangaAnnotationLedger.resolve]）；被校验丢弃的行按页
///   存最近一次结果（[MangaAnnotationLedger.rejected]），复核界面据此列出。
/// - 每卷一个 JSON：`<sha1(bookKey)>.manga-annotate.json`，与演出稿同目录、原子写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';

/// 失败发生在哪一遍。
enum MangaAnnotateStage {
  roster('roster'),
  page('page'),
  review('review');

  const MangaAnnotateStage(this.wire);

  final String wire;

  static MangaAnnotateStage? parse(Object? raw) {
    for (final MangaAnnotateStage s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

/// 失败短码（错误已脱敏，详情只存 AI 客户端给的短码）。
abstract final class MangaAnnotateFailureCode {
  /// 临时性失败（网络 / 限流 / 5xx）重试几轮后仍失败。
  static const String network = 'network';

  /// 非临时性的调用失败（鉴权、4xx、空回复……）；[MangaAnnotateAttempt.detail] 是短码。
  static const String aiFailed = 'ai_failed';

  /// 回复不是约定的 JSON。
  static const String badOutput = 'bad_output';

  /// 回了行，但全部被本地校验丢弃。
  static const String validation = 'validation';

  /// 页图读不出 / 解不开。
  static const String image = 'image';
}

/// 一次失败的尝试。
class MangaAnnotateAttempt {
  const MangaAnnotateAttempt({
    required this.providerId,
    required this.model,
    required this.code,
    this.detail,
    required this.atMs,
  });

  final String providerId;
  final String model;
  final String code;
  final String? detail;
  final int atMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'p': providerId,
    'm': model,
    'c': code,
    if (detail != null) 'd': detail,
    't': atMs,
  };

  static MangaAnnotateAttempt? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? provider = raw['p'];
    final Object? code = raw['c'];
    if (provider is! String || code is! String) return null;
    final Object? model = raw['m'];
    final Object? detail = raw['d'];
    final Object? at = raw['t'];
    return MangaAnnotateAttempt(
      providerId: provider,
      model: model is String ? model : '',
      code: code,
      detail: detail is String ? detail : null,
      atMs: at is int ? at : 0,
    );
  }
}

/// 一处没标成的地方：[stage] + [page]（角色表 = -1；复核 = 该场第一页）。
class MangaAnnotateFailure {
  MangaAnnotateFailure({
    required this.stage,
    required this.page,
    List<int>? scene,
    List<MangaAnnotateAttempt>? attempts,
  }) : scene = scene ?? <int>[],
       attempts = attempts ?? <MangaAnnotateAttempt>[];

  final MangaAnnotateStage stage;
  final int page;

  /// 复核失败时该场的全部页（重试复核用）；其它阶段为空。
  final List<int> scene;

  final List<MangaAnnotateAttempt> attempts;

  String get key => mangaAnnotateFailureKey(stage, page);

  MangaAnnotateAttempt? get last => attempts.isEmpty ? null : attempts.last;

  /// 试过的提供商 id。
  Set<String> get triedProviders => <String>{
    for (final MangaAnnotateAttempt a in attempts) a.providerId,
  };

  /// 「切配置重试」的下一家：[candidates]（可用提供商 id，按用户的列表顺序）里第一家
  /// 还没试过的；都试过返回 null（界面只剩「重试同一家」与手工标）。
  String? nextRetryProvider(List<String> candidates) {
    final Set<String> tried = triedProviders;
    for (final String c in candidates) {
      if (!tried.contains(c)) return c;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    's': stage.wire,
    'p': page,
    if (scene.isNotEmpty) 'scene': scene,
    'tries': <Object?>[
      for (final MangaAnnotateAttempt a in attempts) a.toJson(),
    ],
  };

  static MangaAnnotateFailure? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final MangaAnnotateStage? stage = MangaAnnotateStage.parse(raw['s']);
    final Object? page = raw['p'];
    if (stage == null || page is! int) return null;
    final Object? scene = raw['scene'];
    final Object? tries = raw['tries'];
    return MangaAnnotateFailure(
      stage: stage,
      page: page,
      scene: <int>[
        if (scene is List)
          for (final Object? v in scene)
            if (v is int && v >= 0) v,
      ],
      attempts: <MangaAnnotateAttempt>[
        if (tries is List)
          for (final Object? t in tries)
            if (MangaAnnotateAttempt.fromJson(t)
                case final MangaAnnotateAttempt a)
              a,
      ],
    );
  }
}

String mangaAnnotateFailureKey(MangaAnnotateStage stage, int page) =>
    '${stage.wire}:$page';

/// 被本地校验丢掉的一行（复核界面展示用）。
class MangaRejectedNote {
  const MangaRejectedNote({
    required this.reason,
    required this.blocks,
    this.detail,
  });

  final MangaLineRejection reason;

  /// 原始输出里的块下标（只收整数；可能越界，界面只作提示）。
  final List<int> blocks;
  final String? detail;

  static MangaRejectedNote fromRejected(MangaRejectedLine r) {
    final Object? raw = r.raw;
    final Object? b = raw is Map ? raw['b'] : null;
    return MangaRejectedNote(
      reason: r.reason,
      blocks: <int>[
        if (b is List)
          for (final Object? v in b)
            if (v is int) v,
      ],
      detail: r.detail,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'r': reason.name,
    'b': blocks,
    if (detail != null) 'd': detail,
  };

  static MangaRejectedNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    MangaLineRejection? reason;
    for (final MangaLineRejection r in MangaLineRejection.values) {
      if (r.name == raw['r']) reason = r;
    }
    if (reason == null) return null;
    final Object? b = raw['b'];
    final Object? d = raw['d'];
    return MangaRejectedNote(
      reason: reason,
      blocks: <int>[
        if (b is List)
          for (final Object? v in b)
            if (v is int) v,
      ],
      detail: d is String ? d : null,
    );
  }
}

/// 一卷的标注失败账本。
class MangaAnnotationLedger {
  MangaAnnotationLedger({
    Map<String, MangaAnnotateFailure>? failures,
    Map<int, List<MangaRejectedNote>>? rejected,
  }) : failures = failures ?? <String, MangaAnnotateFailure>{},
       rejected = rejected ?? <int, List<MangaRejectedNote>>{};

  static const int schemaVersion = 1;

  /// [MangaAnnotateFailure.key] → 失败。
  final Map<String, MangaAnnotateFailure> failures;

  /// 页 → 最近一次标注时被校验丢弃的行。
  final Map<int, List<MangaRejectedNote>> rejected;

  bool get isEmpty => failures.isEmpty && rejected.isEmpty;

  MangaAnnotateFailure? failureOf(MangaAnnotateStage stage, int page) =>
      failures[mangaAnnotateFailureKey(stage, page)];

  /// 逐页失败的页（升序）。
  List<int> get failedPages => <int>[
    for (final MangaAnnotateFailure f in failures.values)
      if (f.stage == MangaAnnotateStage.page) f.page,
  ]..sort();

  /// 按阶段、页排好的失败列表（界面用）。
  List<MangaAnnotateFailure> get sortedFailures =>
      failures.values.toList()
        ..sort((MangaAnnotateFailure a, MangaAnnotateFailure b) {
          final int byStage = a.stage.index.compareTo(b.stage.index);
          return byStage != 0 ? byStage : a.page.compareTo(b.page);
        });

  /// 记一次失败（同一处累计尝试）。
  MangaAnnotateFailure recordFailure({
    required MangaAnnotateStage stage,
    required int page,
    required String providerId,
    required String model,
    required String code,
    String? detail,
    List<int> scene = const <int>[],
    DateTime? now,
  }) {
    final MangaAnnotateFailure f = failures.putIfAbsent(
      mangaAnnotateFailureKey(stage, page),
      () => MangaAnnotateFailure(
        stage: stage,
        page: page,
        scene: List<int>.of(scene),
      ),
    );
    f.attempts.add(
      MangaAnnotateAttempt(
        providerId: providerId,
        model: model,
        code: code,
        detail: detail,
        atMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ),
    );
    return f;
  }

  /// 这一处标成功了：删掉失败记录。
  bool resolve(MangaAnnotateStage stage, int page) =>
      failures.remove(mangaAnnotateFailureKey(stage, page)) != null;

  /// 记下某页最近一次被丢弃的行（空 = 清掉）。
  void setRejected(int page, List<MangaRejectedLine> lines) {
    if (lines.isEmpty) {
      rejected.remove(page);
    } else {
      rejected[page] = <MangaRejectedNote>[
        for (final MangaRejectedLine r in lines)
          MangaRejectedNote.fromRejected(r),
      ];
    }
  }

  /// 用户手工标完某页：失败与丢弃记录一起清掉。
  void clearPage(int page) {
    resolve(MangaAnnotateStage.page, page);
    rejected.remove(page);
  }

  /// OCR 重跑、整卷重新标注时清空。
  void clear() {
    failures.clear();
    rejected.clear();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'failures': <Object?>[
      for (final MangaAnnotateFailure f in failures.values) f.toJson(),
    ],
    'rejected': <String, Object?>{
      for (final MapEntry<int, List<MangaRejectedNote>> e in rejected.entries)
        '${e.key}': <Object?>[
          for (final MangaRejectedNote n in e.value) n.toJson(),
        ],
    },
  };

  static MangaAnnotationLedger fromJson(Object? raw) {
    if (raw is! Map) return MangaAnnotationLedger();
    final Object? failures = raw['failures'];
    final Object? rejected = raw['rejected'];
    final Map<int, List<MangaRejectedNote>> notes =
        <int, List<MangaRejectedNote>>{};
    if (rejected is Map) {
      for (final MapEntry<Object?, Object?> e in rejected.entries) {
        final int? page = int.tryParse('${e.key}');
        final Object? list = e.value;
        if (page == null || page < 0 || list is! List) continue;
        final List<MangaRejectedNote> parsed = <MangaRejectedNote>[
          for (final Object? n in list)
            if (MangaRejectedNote.fromJson(n) case final MangaRejectedNote note)
              note,
        ];
        if (parsed.isNotEmpty) notes[page] = parsed;
      }
    }
    return MangaAnnotationLedger(
      failures: <String, MangaAnnotateFailure>{
        if (failures is List)
          for (final Object? f in failures)
            if (MangaAnnotateFailure.fromJson(f)
                case final MangaAnnotateFailure x)
              x.key: x,
      },
      rejected: notes,
    );
  }
}

/// 每卷一份账本：`<root>/<sha1(bookKey)>.manga-annotate.json`。
class MangaAnnotationLedgerStore {
  MangaAnnotationLedgerStore(this.root);

  final Directory root;

  File fileFor(String bookKey) => File(
    p.join(
      root.path,
      '${sha1.convert(utf8.encode(bookKey))}.manga-annotate.json',
    ),
  );

  Future<MangaAnnotationLedger> load(String bookKey) async {
    final File f = fileFor(bookKey);
    if (!await f.exists()) return MangaAnnotationLedger();
    try {
      return MangaAnnotationLedger.fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return MangaAnnotationLedger();
    }
  }

  /// 原子写；账本空了就删文件。
  Future<void> save(String bookKey, MangaAnnotationLedger ledger) async {
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

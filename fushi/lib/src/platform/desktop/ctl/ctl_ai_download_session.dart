/// 「AI 下载」会话的控制通道承载（与 AppModel 无关，便于单测）。
///
/// 两类会话共用一张会话表（引擎的 [HostAssistantSessions]：随机 id、闲置回收、
/// 长轮询），CLI 只认会话 id：
///
/// - `video`：「AI 下视频」——直接复用互联 host 的 [VideoAcquisitionHostSession]
///   （与手机经 `/api/assistant` 让电脑代办同一个状态机与动作形状）；
/// - `novel` / `manga` / `game`：「AI 下载」页——[CtlMediaAcquisitionSession] 包住
///   页面同一个 [runMediaAcquisitionSearch]（AI 解析 → 本地搜 → AI 推荐），候选由
///   CLI 选定、确认后才按该候选来源既有的下载路径执行（AI 永远不直接触发下载）。
library;

import 'dart:async';

import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/acquisition/media_acquisition_backends.dart';
import 'package:fushi/src/pages/implementations/ai_media_acquisition_page.dart'
    show
        MediaAcquisitionSearchPhase,
        MediaAcquisitionSearchSnapshot,
        runMediaAcquisitionSearch;

/// 会话种类（CLI `--domain`）。
enum CtlAiDownloadFeature {
  /// AI 下视频（对话式，host 状态机）。
  video,

  /// AI 下载：小说 / 有声书。
  novel,

  /// AI 下载：漫画。
  manga,

  /// AI 下载：游戏。
  game;

  static CtlAiDownloadFeature parse(String? raw) {
    final String value = (raw ?? '').trim().toLowerCase();
    for (final CtlAiDownloadFeature f in values) {
      if (f.name == value) return f;
    }
    switch (value) {
      case 'anime':
        return CtlAiDownloadFeature.video;
      case 'book' || 'books' || 'audiobook':
        return CtlAiDownloadFeature.novel;
      case 'games':
        return CtlAiDownloadFeature.game;
    }
    throw CtlFailure.badRequest('未知 domain：$raw（video | novel | manga | game）');
  }

  /// 对应的「AI 下载」域；视频为 null。
  AiMediaAcquisitionDomain? get mediaDomain => switch (this) {
    CtlAiDownloadFeature.video => null,
    CtlAiDownloadFeature.novel => AiMediaAcquisitionDomain.novel,
    CtlAiDownloadFeature.manga => AiMediaAcquisitionDomain.manga,
    CtlAiDownloadFeature.game => AiMediaAcquisitionDomain.game,
  };
}

/// 确认一条候选后的结果。
class CtlMediaAcquireOutcome {
  const CtlMediaAcquireOutcome({
    required this.started,
    this.taskId,
    this.message,
  });

  /// 是否已交给下载 / 入库。
  final bool started;

  /// 有可查进度 / 可取消的 CLI 任务时（小说整本下载）的任务 id。
  final String? taskId;

  /// 没开始时的原因（或开始后的补充说明）。
  final String? message;
}

/// 一条候选在会话里的下载状态。
enum CtlMediaCandidateStatus { idle, acquiring, started, failed }

/// 「AI 下载」（小说 / 漫画 / 游戏）的一场 CLI 会话。
///
/// 动作形状与 [VideoAcquisitionHostSession] 对齐：
///
/// ```
/// {type: text, text}                 新一轮：一句话 → 搜索词 → 候选 → 推荐
/// {type: choose, optionIds: [...]}   选定候选（候选 id 或 1 起序号；替换此前的选择）
/// {type: confirm}                    按各候选来源既有路径下载已选候选
/// {type: cancel}                     停止搜索、取消本会话发起的可取消下载
/// {type: restart}                    回到空闲
/// ```
///
/// 形状不对抛 [ArgumentError]（路由 400），此刻不能做抛 [StateError]（路由 409）。
class CtlMediaAcquisitionSession implements HostAssistantSession {
  CtlMediaAcquisitionSession({
    required this.domain,
    required AiMediaAcquisitionAi ai,
    required List<MediaAcquisitionBackend> backends,
    required Future<CtlMediaAcquireOutcome> Function(
      MediaAcquisitionCandidate candidate,
    )
    acquire,
    void Function(String taskId)? cancelTask,
  }) : _ai = ai,
       _backends = backends,
       _acquire = acquire,
       _cancelTask = cancelTask;

  final AiMediaAcquisitionDomain domain;
  final AiMediaAcquisitionAi _ai;
  final List<MediaAcquisitionBackend> _backends;
  final Future<CtlMediaAcquireOutcome> Function(MediaAcquisitionCandidate)
  _acquire;
  final void Function(String taskId)? _cancelTask;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  int _revision = 0;
  int _generation = 0;
  bool _closed = false;

  /// `idle` / `parsing` / `searching` / `picking` / `ready` / `cancelled`。
  String _stage = 'idle';
  String? _utterance;
  String? _error;
  MediaAcquisitionSearchSnapshot? _search;
  final Set<String> _selected = <String>{};
  final Map<String, CtlMediaCandidateStatus> _status =
      <String, CtlMediaCandidateStatus>{};
  final Map<String, String> _taskIds = <String, String>{};
  final Map<String, String> _messages = <String, String>{};

  @override
  int get revision => _revision;

  @override
  Stream<void> get changes => _changes.stream;

  List<MediaAcquisitionCandidate> get _candidates =>
      _search?.candidates ?? const <MediaAcquisitionCandidate>[];

  bool get _busy =>
      _stage == 'parsing' ||
      _stage == 'searching' ||
      _stage == 'picking' ||
      _status.values.contains(CtlMediaCandidateStatus.acquiring);

  void _changed() {
    _revision++;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Map<String, Object?> snapshot() {
    final List<MediaAcquisitionCandidate> candidates = _candidates;
    final Set<String> picks = <String>{...?_search?.picks};
    return <String, Object?>{
      'domain': domain.name,
      'stage': _stage,
      'busy': _busy,
      if (_utterance != null) 'utterance': _utterance,
      'queries': _search?.queries ?? const <String>[],
      'aiDegraded': _search?.aiDegraded ?? false,
      if (_error != null) 'error': _error,
      'candidates': <Map<String, Object?>>[
        for (int i = 0; i < candidates.length; i++)
          <String, Object?>{
            'no': i + 1,
            'id': candidates[i].id,
            'title': candidates[i].title,
            'source': candidates[i].sourceLabel,
            'details': candidates[i].details,
            'method': candidates[i].method.name,
            'external': candidates[i].externalSource,
            'recommended': picks.contains(candidates[i].id),
            'selected': _selected.contains(candidates[i].id),
            'status':
                (_status[candidates[i].id] ?? CtlMediaCandidateStatus.idle)
                    .name,
            if (_taskIds[candidates[i].id] case final String taskId)
              'taskId': taskId,
            if (_messages[candidates[i].id] case final String message)
              'message': message,
          },
      ],
    };
  }

  @override
  Future<void> act(Map<String, Object?> action) async {
    if (_closed) throw StateError('会话已关闭');
    switch (action['type']) {
      case 'text':
        final Object? text = action['text'];
        if (text is! String || text.trim().isEmpty) {
          throw ArgumentError('text 动作需要非空 text');
        }
        _startSearch(text.trim());
      case 'choose':
        _choose(action);
      case 'confirm':
        _confirm();
      case 'cancel':
        _cancel();
      case 'restart':
        _generation++;
        _stage = 'idle';
        _utterance = null;
        _search = null;
        _selected.clear();
        _changed();
      default:
        throw ArgumentError('未知动作：${action['type']}');
    }
  }

  void _startSearch(String utterance) {
    final int generation = ++_generation;
    _utterance = utterance;
    _error = null;
    _stage = 'parsing';
    _search = const MediaAcquisitionSearchSnapshot(
      phase: MediaAcquisitionSearchPhase.parsing,
    );
    _selected.clear();
    _status.clear();
    _taskIds.clear();
    _messages.clear();
    _changed();
    unawaited(
      runMediaAcquisitionSearch(
        ai: _ai,
        domain: domain,
        backends: _backends,
        utterance: utterance,
        isStale: () => _closed || generation != _generation,
        onUpdate: (MediaAcquisitionSearchSnapshot snapshot) {
          _search = snapshot;
          _stage = switch (snapshot.phase) {
            MediaAcquisitionSearchPhase.parsing => 'parsing',
            MediaAcquisitionSearchPhase.searching => 'searching',
            MediaAcquisitionSearchPhase.picking => 'picking',
            MediaAcquisitionSearchPhase.done => 'ready',
          };
          _changed();
        },
      ).catchError((Object error) {
        // 后端单源失败已在各自内部吞掉；走到这里是编排本身的异常。
        if (_closed || generation != _generation) return null;
        _stage = 'ready';
        _error = '$error';
        _changed();
        return null;
      }),
    );
  }

  /// 候选 id 或 1 起序号 → 候选。
  MediaAcquisitionCandidate _resolveCandidate(String raw) {
    final List<MediaAcquisitionCandidate> candidates = _candidates;
    for (final MediaAcquisitionCandidate c in candidates) {
      if (c.id == raw) return c;
    }
    final int? n = int.tryParse(raw.trim().replaceFirst('#', ''));
    if (n != null && n >= 1 && n <= candidates.length) return candidates[n - 1];
    throw ArgumentError('没有候选 $raw（共 ${candidates.length} 条）');
  }

  void _choose(Map<String, Object?> action) {
    if (_stage != 'ready') {
      throw StateError('候选还没出来（当前 $_stage），等搜索完成后再选');
    }
    final Object? many = action['optionIds'];
    final Object? one = action['optionId'];
    final List<String> raws = <String>[
      if (many is List)
        for (final Object? item in many) '$item'
      else if (one != null)
        '$one',
    ];
    if (raws.isEmpty) throw ArgumentError('choose 需要 optionIds');
    final List<MediaAcquisitionCandidate> picked = <MediaAcquisitionCandidate>[
      for (final String raw in raws) _resolveCandidate(raw),
    ];
    _selected
      ..clear()
      ..addAll(<String>[
        for (final MediaAcquisitionCandidate c in picked) c.id,
      ]);
    _changed();
  }

  void _confirm() {
    if (_stage != 'ready') {
      throw StateError('候选还没出来（当前 $_stage）');
    }
    final List<MediaAcquisitionCandidate> targets = <MediaAcquisitionCandidate>[
      for (final MediaAcquisitionCandidate c in _candidates)
        if (_selected.contains(c.id) &&
            _status[c.id] != CtlMediaCandidateStatus.acquiring &&
            _status[c.id] != CtlMediaCandidateStatus.started)
          c,
    ];
    if (targets.isEmpty) {
      throw StateError(_selected.isEmpty ? '还没选候选（先 choose）' : '已选候选都已开始下载');
    }
    final int generation = _generation;
    for (final MediaAcquisitionCandidate c in targets) {
      _status[c.id] = CtlMediaCandidateStatus.acquiring;
      _messages.remove(c.id);
    }
    _changed();
    for (final MediaAcquisitionCandidate c in targets) {
      unawaited(() async {
        CtlMediaAcquireOutcome outcome;
        try {
          outcome = await _acquire(c);
        } on Object catch (error) {
          outcome = CtlMediaAcquireOutcome(started: false, message: '$error');
        }
        if (_closed || generation != _generation) {
          // 会话已取消 / 换轮：刚起的可取消任务一并取消，不留孤儿。
          if (outcome.taskId case final String taskId) {
            _cancelTask?.call(taskId);
          }
          return;
        }
        _status[c.id] = outcome.started
            ? CtlMediaCandidateStatus.started
            : CtlMediaCandidateStatus.failed;
        if (outcome.taskId case final String taskId) _taskIds[c.id] = taskId;
        if (outcome.message case final String message) {
          _messages[c.id] = message;
        }
        _changed();
      }());
    }
  }

  void _cancel() {
    _generation++;
    for (final String taskId in _taskIds.values) {
      _cancelTask?.call(taskId);
    }
    for (final MapEntry<String, CtlMediaCandidateStatus> e
        in _status.entries.toList()) {
      if (e.value == CtlMediaCandidateStatus.acquiring) {
        _status[e.key] = CtlMediaCandidateStatus.failed;
        _messages[e.key] = '已取消';
      }
    }
    _stage = 'cancelled';
    _changed();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    await _changes.close();
  }
}

/// 视频会话的 `choose`：按当前问题把 CLI 的回答换成 `{type: choose, slot, optionId}`。
///
/// [answer] 先按选项 id 精确匹配，再按 1 起序号，最后按选项文字（不区分大小写）。
/// 没有待答问题抛 [StateError]（409），答案不在选项里抛 [ArgumentError]（400）。
Map<String, Object?> resolveCtlVideoChoice(
  Map<String, Object?> view,
  String answer, {
  bool? remember,
}) {
  final Object? question = view['question'];
  if (question is! Map) {
    throw StateError('会话当前没有待回答的问题（stage=${view['stage']}）');
  }
  final List<Map<Object?, Object?>> options = <Map<Object?, Object?>>[
    if (question['options'] is List)
      for (final Object? o in question['options'] as List)
        if (o is Map) o,
  ];
  final String text = answer.trim();
  Map<Object?, Object?>? hit;
  for (final Map<Object?, Object?> o in options) {
    if (o['id'] == text) hit = o;
  }
  if (hit == null) {
    final int? n = int.tryParse(text.replaceFirst('#', ''));
    if (n != null && n >= 1 && n <= options.length) hit = options[n - 1];
  }
  if (hit == null) {
    final String lower = text.toLowerCase();
    for (final Map<Object?, Object?> o in options) {
      if ('${o['label'] ?? ''}'.toLowerCase() == lower) hit = o;
    }
  }
  if (hit == null) {
    throw ArgumentError(
      '问题 ${question['slot']} 没有选项「$text」'
      '（可选：${<String>[for (int i = 0; i < options.length; i++) '${i + 1}=${options[i]['id']}'].join(' / ')}）',
    );
  }
  return <String, Object?>{
    'type': 'choose',
    'slot': question['slot'],
    'optionId': hit['id'],
    if (remember != null) 'remember': remember,
  };
}

/// 把会话表的「开不了」统一成控制通道失败。
CtlFailure ctlAiDownloadUnavailable(HostAssistantUnavailable error) =>
    CtlFailure.rejected(switch (error.reason) {
      'no_provider' => '没有给「AI 下载」指派 LLM 提供商（设置 › 模型 › LLM）',
      'not_ready' => '下载后端未就绪或没有受管的视频来源（设置 › 下载）',
      'disabled' => '本平台构建 / 模块开关不提供这项 AI 下载',
      _ => 'AI 下载不可用：${error.reason}',
    });

/// 一场会话的登记信息。
class CtlAiDownloadSessionInfo {
  CtlAiDownloadSessionInfo({
    required this.id,
    required this.feature,
    required this.createdAt,
  });

  final String id;
  final CtlAiDownloadFeature feature;
  final int createdAt;
}

/// 开一场会话：按种类分派到视频 host 或「AI 下载」会话。
typedef CtlAiDownloadOpener =
    Future<HostAssistantSession> Function(CtlAiDownloadFeature feature);

/// [HostAssistantSessions] 只认 `feature` 字符串：这里把 CLI 的种类接过去。
class _CtlAiDownloadProvider implements HostAssistantProvider {
  _CtlAiDownloadProvider(this._open);

  final CtlAiDownloadOpener _open;

  @override
  Future<Map<String, Object?>> capability() async => const <String, Object?>{
    'supported': true,
  };

  @override
  Future<HostAssistantSession> open(String feature, {required String locale}) =>
      _open(CtlAiDownloadFeature.parse(feature));
}

/// CLI 的 AI 下载会话表：引擎会话表 + 种类登记（列表 / 分派用）。
class CtlAiDownloadSessions {
  CtlAiDownloadSessions(
    CtlAiDownloadOpener open, {
    Duration idleTimeout = const Duration(minutes: 30),
    int Function()? clock,
  }) : _sessions = HostAssistantSessions(
         _CtlAiDownloadProvider(open),
         idleTimeout: idleTimeout,
       ),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final HostAssistantSessions _sessions;
  final int Function() _clock;
  final Map<String, CtlAiDownloadSessionInfo> _info =
      <String, CtlAiDownloadSessionInfo>{};

  /// 状态长轮询的单次上限（低于 CLI 默认 90 秒超时）。
  static const Duration maxWait = Duration(seconds: 80);

  Map<String, Object?> _withInfo(Map<String, Object?> envelope) {
    final CtlAiDownloadSessionInfo? info = _info['${envelope['id']}'];
    return <String, Object?>{
      ...envelope,
      if (info != null) 'domain': info.feature.name,
    };
  }

  CtlAiDownloadSessionInfo info(String id) {
    final CtlAiDownloadSessionInfo? info = _info[id];
    if (info == null) throw CtlFailure.notFound('没有这个会话：$id（已关闭或闲置过期）');
    return info;
  }

  /// 开会话并递上第一句话；返回首个信封 `{id, domain, revision, view}`。
  Future<Map<String, Object?>> start(
    CtlAiDownloadFeature feature,
    String text,
  ) async {
    final Map<String, Object?> envelope;
    try {
      envelope = await _sessions.open(feature.name, locale: '');
    } on HostAssistantUnavailable catch (error) {
      throw ctlAiDownloadUnavailable(error);
    }
    final String id = '${envelope['id']}';
    _info[id] = CtlAiDownloadSessionInfo(
      id: id,
      feature: feature,
      createdAt: _clock(),
    );
    return act(id, <String, Object?>{'type': 'text', 'text': text});
  }

  /// 读快照；[wait] 非零时等到会话不忙（或超时），中途每次变化都重新判断。
  Future<Map<String, Object?>> read(
    String id, {
    Duration wait = Duration.zero,
  }) async {
    info(id);
    final DateTime deadline = DateTime.now().add(
      wait > maxWait ? maxWait : wait,
    );
    Map<String, Object?>? envelope = await _sessions.read(id);
    while (envelope != null) {
      final Object? view = envelope['view'];
      final bool busy = view is Map && view['busy'] == true;
      final Duration left = deadline.difference(DateTime.now());
      if (!busy || left <= Duration.zero) break;
      envelope = await _sessions.read(
        id,
        after: envelope['revision'] as int?,
        wait: left,
      );
    }
    if (envelope == null) {
      _info.remove(id);
      throw CtlFailure.notFound('没有这个会话：$id（已关闭或闲置过期）');
    }
    return _withInfo(envelope);
  }

  /// 执行动作后回当前快照。
  Future<Map<String, Object?>> act(
    String id,
    Map<String, Object?> action,
  ) async {
    info(id);
    final Map<String, Object?>? envelope;
    try {
      envelope = await _sessions.act(id, action);
    } on ArgumentError catch (error) {
      throw CtlFailure.badRequest('${error.message}');
    } on StateError catch (error) {
      throw CtlFailure.conflict(error.message);
    }
    if (envelope == null) {
      _info.remove(id);
      throw CtlFailure.notFound('没有这个会话：$id（已关闭或闲置过期）');
    }
    return _withInfo(envelope);
  }

  Future<bool> close(String id) async {
    _info.remove(id);
    return _sessions.close(id);
  }

  /// 还活着的会话（顺带清掉引擎已回收的登记）。
  Future<List<Map<String, Object?>>> list() async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final CtlAiDownloadSessionInfo info in _info.values.toList()) {
      final Map<String, Object?>? envelope = await _sessions.read(info.id);
      if (envelope == null) {
        _info.remove(info.id);
        continue;
      }
      final Object? view = envelope['view'];
      out.add(<String, Object?>{
        'id': info.id,
        'domain': info.feature.name,
        'createdAt': info.createdAt,
        'stage': view is Map ? view['stage'] : null,
        'busy': view is Map && view['busy'] == true,
      });
    }
    return out;
  }
}

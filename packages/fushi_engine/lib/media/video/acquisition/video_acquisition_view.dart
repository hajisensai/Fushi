/// 「AI 下视频」对话页的**渲染快照**与会话接口。
///
/// 对话页只渲染 [VideoAcquisitionView]、只经 [VideoAcquisitionSession] 发动作；它不知
/// 道会话跑在哪台设备上：
///
/// - 本机：[VideoAcquisitionService] 自己就是会话，视图由 [projectVideoAcquisitionView]
///   从完整状态投影出来。
/// - 电脑代办（手机 → 互联 → 电脑的 AI）：状态机跑在 host 上，视图经
///   [VideoAcquisitionView.toJson] 过线，手机端 `RemoteVideoAcquisitionSession` 还原。
///
/// 视图与语言无关：助手发言仍是 [VideoAcquisitionSay]（种类 + 参数）、问题仍是
/// (slot, option id)，文案由**渲染它的那台设备**按自己的界面语言取 i18n。只有版本
/// 标签这类字面量事实（压制组 · 分辨率 · 片源 · 体积）在投影时拼好。
library;

import 'package:fushi_engine/media/discovery/discovery_format.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart'
    show videoAcquisitionWorkActions;
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendUnavailable;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;

/// 失败时页面能给的「解决它」的按钮（SnackBar 动作）。从编排器的原始异常推出来，
/// 这样过线后手机端也知道该给什么（虽然远端时「去配置下载后端」不渲染——那是电
/// 脑的后端）。
enum VideoAcquisitionFailureHint {
  none,

  /// 下载后端不可用：给「去配置」。
  configureBackend,

  /// 后端根本没配（`ArgumentError`）：换成「未配置下载后端」文案 + 「去配置」。
  backendNotConfigured,

  /// 管线要求用户处理后重试：给「重试」（= 再确认一次）。
  retry,
}

/// 远端会话自己的失败短码（host 连不上 / 会话在 host 上已失效）。经
/// [VideoAcquisitionSayKind.failed] 的 `message` 参数进对话记录，页面翻成人话。
const String kVideoAcquisitionFailureRemoteUnavailable = 'remote_unavailable';

/// 整套清单的一行（已投影成纯数据）。
class VideoAcquisitionFranchiseRowView {
  const VideoAcquisitionFranchiseRowView({
    required this.title,
    this.year,
    this.status = VideoAcquisitionFranchiseEntryStatus.pending,
    this.mode = VideoAcquisitionMode.download,
    this.versionLabel,
    this.selected = true,
    this.owned = false,
    this.submittable = false,
  });

  final String title;
  final int? year;
  final VideoAcquisitionFranchiseEntryStatus status;
  final VideoAcquisitionMode mode;

  /// ready 行的版本标签（字面量事实）；其它状态为 null。
  final String? versionLabel;
  final bool selected;
  final bool owned;
  final bool submittable;
}

/// 对话页需要的一切，且只有这些。
class VideoAcquisitionView {
  const VideoAcquisitionView({
    this.stage = VideoAcquisitionStage.idle,
    this.busy = false,
    this.transcript = const <VideoAcquisitionMessage>[],
    this.question,
    this.workActions = const <String>[],
    this.workCandidateCategories = const <VideoDiscoveryCategory?>[],
    this.alternativeLabels = const <String>[],
    this.franchise = const <VideoAcquisitionFranchiseRowView>[],
    this.failureHint = VideoAcquisitionFailureHint.none,
  });

  final VideoAcquisitionStage stage;
  final bool busy;
  final List<VideoAcquisitionMessage> transcript;
  final VideoAcquisitionQuestion? question;

  /// 作品操作条（换一部 / 整个系列…），见 [videoAcquisitionWorkActions]。
  final List<String> workActions;

  /// 作品候选（按 `work` 问题的选项下标）的类别，页面翻成「剧集 / 动画 / 电影」。
  final List<VideoDiscoveryCategory?> workCandidateCategories;

  /// 候选版本（按 `alt:<i>` 选项下标）的标签。
  final List<String> alternativeLabels;
  final List<VideoAcquisitionFranchiseRowView> franchise;
  final VideoAcquisitionFailureHint failureHint;

  bool get finished =>
      stage == VideoAcquisitionStage.done ||
      stage == VideoAcquisitionStage.cancelled;

  VideoAcquisitionView copyWith({
    bool? busy,
    List<VideoAcquisitionMessage>? transcript,
    VideoAcquisitionFailureHint? failureHint,
  }) => VideoAcquisitionView(
    stage: stage,
    busy: busy ?? this.busy,
    transcript: transcript ?? this.transcript,
    question: question,
    workActions: workActions,
    workCandidateCategories: workCandidateCategories,
    alternativeLabels: alternativeLabels,
    franchise: franchise,
    failureHint: failureHint ?? this.failureHint,
  );

  // ---------------------------------------------------------------------------
  // wire（互联 `/api/assistant` 的 `view` 字段）
  // ---------------------------------------------------------------------------

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage.name,
    'busy': busy,
    'transcript': <Map<String, Object?>>[
      for (final VideoAcquisitionMessage message in transcript)
        _messageToJson(message),
    ],
    if (question != null) 'question': _questionToJson(question!),
    'workActions': workActions,
    'workCandidateCategories': <String?>[
      for (final VideoDiscoveryCategory? category in workCandidateCategories)
        category?.name,
    ],
    'alternativeLabels': alternativeLabels,
    'franchise': <Map<String, Object?>>[
      for (final VideoAcquisitionFranchiseRowView row in franchise)
        <String, Object?>{
          'title': row.title,
          if (row.year != null) 'year': row.year,
          'status': row.status.name,
          'mode': row.mode.name,
          if (row.versionLabel != null) 'versionLabel': row.versionLabel,
          'selected': row.selected,
          'owned': row.owned,
          'submittable': row.submittable,
        },
    ],
    'failureHint': failureHint.name,
  };

  /// 容忍新版 host：认不出的发言种类 / 槽位整条跳过，不让整页解析失败。
  factory VideoAcquisitionView.fromJson(Map<String, Object?> json) {
    final VideoAcquisitionQuestion? question = _questionFromJson(
      json['question'],
    );
    return VideoAcquisitionView(
      stage:
          _enumByName(VideoAcquisitionStage.values, json['stage']) ??
          VideoAcquisitionStage.idle,
      busy: json['busy'] == true,
      transcript: <VideoAcquisitionMessage>[
        for (final Object? raw in _list(json['transcript']))
          if (_messageFromJson(raw) case final VideoAcquisitionMessage message)
            message,
      ],
      question: question,
      workActions: <String>[
        for (final Object? id in _list(json['workActions'])) '$id',
      ],
      workCandidateCategories: <VideoDiscoveryCategory?>[
        for (final Object? raw in _list(json['workCandidateCategories']))
          _enumByName(VideoDiscoveryCategory.values, raw),
      ],
      alternativeLabels: <String>[
        for (final Object? label in _list(json['alternativeLabels'])) '$label',
      ],
      franchise: <VideoAcquisitionFranchiseRowView>[
        for (final Object? raw in _list(json['franchise']))
          if (raw is Map)
            VideoAcquisitionFranchiseRowView(
              title: '${raw['title'] ?? ''}',
              year: (raw['year'] as num?)?.toInt(),
              status:
                  _enumByName(
                    VideoAcquisitionFranchiseEntryStatus.values,
                    raw['status'],
                  ) ??
                  VideoAcquisitionFranchiseEntryStatus.pending,
              mode:
                  _enumByName(VideoAcquisitionMode.values, raw['mode']) ??
                  VideoAcquisitionMode.download,
              versionLabel: raw['versionLabel'] as String?,
              selected: raw['selected'] == true,
              owned: raw['owned'] == true,
              submittable: raw['submittable'] == true,
            ),
      ],
      failureHint:
          _enumByName(
            VideoAcquisitionFailureHint.values,
            json['failureHint'],
          ) ??
          VideoAcquisitionFailureHint.none,
    );
  }
}

/// 对话页消费的会话：本机 [VideoAcquisitionService] 或远端代办。
abstract interface class VideoAcquisitionSession {
  VideoAcquisitionView get view;
  Stream<VideoAcquisitionView> get views;

  Future<void> submitText(String text);
  Future<void> choose(
    VideoAcquisitionSlot slot,
    String optionId, {
    bool? remember,
  });
  Future<void> confirm();
  Future<void> cancel();
  Future<void> restart();
  Future<void> toggleFranchiseEntry(int index);
  void dispose();
}

/// 版本标签：`组 · 分辨率 · 片源 · 编码 · 每集体积`（全是字面量事实，不翻译）。
String videoAcquisitionVersionLabel(VideoResourceVersionGroup group) {
  final int? bytes = estimatedBytesPerEpisode(group);
  return <String>[
    if (group.releaseGroup != null) group.releaseGroup!,
    if (group.resolution != null) group.resolution!,
    if (videoResourceSourceTag(group) case final String source) source,
    if (videoResourceTraitsTag(group) case final String traits) traits,
    if (bytes != null) formatDiscoveryBytes(bytes),
  ].join(' · ');
}

/// 从完整状态投影出页面视图。[lastError] 是编排器最近一次的原始异常，只用来推
/// [VideoAcquisitionView.failureHint]。
VideoAcquisitionView projectVideoAcquisitionView(
  VideoAcquisitionState state, {
  Object? lastError,
}) => VideoAcquisitionView(
  stage: state.stage,
  busy: state.busy,
  transcript: state.transcript,
  question: state.question,
  workActions: videoAcquisitionWorkActions(state),
  workCandidateCategories: <VideoDiscoveryCategory?>[
    for (final VideoDiscoveryItem item in state.workCandidates)
      item.reference.discoveryCategory,
  ],
  alternativeLabels: <String>[
    for (final VideoResourceVersionGroup group in state.eligibleGroups)
      videoAcquisitionVersionLabel(group),
  ],
  franchise: <VideoAcquisitionFranchiseRowView>[
    for (final VideoAcquisitionFranchiseEntry entry in state.franchiseEntries)
      VideoAcquisitionFranchiseRowView(
        title: entry.item.reference.title,
        year: entry.item.reference.year,
        status: entry.status,
        mode: entry.mode,
        versionLabel:
            entry.status == VideoAcquisitionFranchiseEntryStatus.ready &&
                entry.plan != null
            ? videoAcquisitionVersionLabel(entry.plan!.group)
            : null,
        selected: entry.selected,
        owned: entry.owned,
        submittable: entry.submittable,
      ),
  ],
  failureHint: switch (lastError) {
    VideoDownloadBackendUnavailable() =>
      VideoAcquisitionFailureHint.configureBackend,
    ArgumentError() => VideoAcquisitionFailureHint.backendNotConfigured,
    VideoDownloadPipelineActionRequired() => VideoAcquisitionFailureHint.retry,
    _ => VideoAcquisitionFailureHint.none,
  },
);

// -----------------------------------------------------------------------------
// JSON 细节
// -----------------------------------------------------------------------------

List<Object?> _list(Object? raw) => raw is List ? raw : const <Object?>[];

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final T value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// 参数只允许 JSON 原生值：reducer 放的本来就是字符串 / 数字 / 布尔 / 列表，这里再兜
/// 一层，任何别的东西都转成字符串，保证 `jsonEncode` 不炸。
Object? _jsonSafe(Object? value) => switch (value) {
  null || String() || num() || bool() => value,
  List() => <Object?>[for (final Object? item in value) _jsonSafe(item)],
  Map() => <String, Object?>{
    for (final MapEntry<Object?, Object?> e in value.entries)
      '${e.key}': _jsonSafe(e.value),
  },
  _ => '$value',
};

Map<String, Object?> _args(Map<String, Object?> args) => <String, Object?>{
  for (final MapEntry<String, Object?> e in args.entries)
    e.key: _jsonSafe(e.value),
};

Map<String, Object?> _argsFromJson(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : const <String, Object?>{};

Map<String, Object?> _messageToJson(VideoAcquisitionMessage message) =>
    switch (message) {
      VideoAcquisitionUserMessage(:final String text) => <String, Object?>{
        'role': 'user',
        'text': text,
      },
      VideoAcquisitionAssistantMessage(
        :final VideoAcquisitionSay say,
        :final VideoAcquisitionQuestion? question,
      ) =>
        <String, Object?>{
          'role': 'assistant',
          'kind': say.kind.name,
          'args': _args(say.args),
          if (question != null) 'question': _questionToJson(question),
        },
    };

VideoAcquisitionMessage? _messageFromJson(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['role']) {
    case 'user':
      return VideoAcquisitionUserMessage('${raw['text'] ?? ''}');
    case 'assistant':
      final VideoAcquisitionSayKind? kind = _enumByName(
        VideoAcquisitionSayKind.values,
        raw['kind'],
      );
      if (kind == null) return null;
      final VideoAcquisitionQuestion? question = _questionFromJson(
        raw['question'],
      );
      // 问句本身没有独立文案：槽位认不出时整条跳过，而不是渲染一个空气泡。
      if (kind == VideoAcquisitionSayKind.question && question == null) {
        return null;
      }
      return VideoAcquisitionAssistantMessage(
        VideoAcquisitionSay(kind, args: _argsFromJson(raw['args'])),
        question: question,
      );
  }
  return null;
}

Map<String, Object?> _questionToJson(VideoAcquisitionQuestion q) =>
    <String, Object?>{
      'slot': q.slot.name,
      'options': <Map<String, Object?>>[
        for (final VideoAcquisitionOption o in q.options)
          <String, Object?>{
            'id': o.id,
            if (o.label != null) 'label': o.label,
            if (o.hint != null) 'hint': o.hint,
            if (o.args.isNotEmpty) 'args': _args(o.args),
          },
      ],
      'rememberToggle': q.rememberToggle,
      'rememberDefault': q.rememberDefault,
      if (q.preselectedIndex != null) 'preselectedIndex': q.preselectedIndex,
      'args': _args(q.args),
    };

VideoAcquisitionQuestion? _questionFromJson(Object? raw) {
  if (raw is! Map) return null;
  final VideoAcquisitionSlot? slot = _enumByName(
    VideoAcquisitionSlot.values,
    raw['slot'],
  );
  if (slot == null) return null;
  return VideoAcquisitionQuestion(
    slot: slot,
    options: <VideoAcquisitionOption>[
      for (final Object? o in _list(raw['options']))
        if (o is Map)
          VideoAcquisitionOption(
            id: '${o['id'] ?? ''}',
            label: o['label'] as String?,
            hint: o['hint'] as String?,
            args: _argsFromJson(o['args']),
          ),
    ],
    rememberToggle: raw['rememberToggle'] == true,
    rememberDefault: raw['rememberDefault'] != false,
    preselectedIndex: (raw['preselectedIndex'] as num?)?.toInt(),
    args: _argsFromJson(raw['args']),
  );
}

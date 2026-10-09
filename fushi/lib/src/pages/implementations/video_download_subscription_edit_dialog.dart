import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart'
    show kVideoSubscriptionTitleExcludeKey, kVideoSubscriptionTitleIncludeKey;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaSourceRow, VideoDownloadSubscriptionRow;

/// 编辑订阅的**窄面**结果。来源身份（resourceProvider / fingerprint / backend*）
/// 刻意不可编辑——任务复用判据按它们认（同一集再派一份新任务）。版本规则里只开放
/// 用户真正要换的几项：字幕组、分辨率、标题包含 / 排除关键词（「换字幕组很费劲」，
/// 以前只能删了重订）。改规则只影响还没认领的集：已下载 / 在途的集按逻辑集键
/// 认领过，不会因为换组再派一份。
class VideoDownloadSubscriptionEdit {
  const VideoDownloadSubscriptionEdit({
    required this.searchQuery,
    required this.startAfterEpisode,
    required this.subtitlePolicy,
    required this.targetSourceId,
    this.filterJson,
  });

  final String searchQuery;

  /// 改过的版本规则 JSON；**null = 规则没动，宿主不得写这一列**（与
  /// [targetSourceId] 同一纪律）。
  final String? filterJson;
  final int? startAfterEpisode;
  final VideoDownloadSubtitlePolicy subtitlePolicy;

  /// 目标来源：**null = 用户没改这一列，宿主不得写它**。
  ///
  /// 不能用「当前绑定不在可用列表里就退到第一个」那种写法：
  /// getManagedVideoDownloadSources 按 `Directory(rootPath).existsSync()` 过滤，
  /// 外置盘一拔，订阅原本的目标库就从列表里消失 —— 用户只想改个搜索词，一保存
  /// 目标库被静默改写到一个无关的库，之后整季新集全导进错地方且没有任何提示。
  /// 保留原绑定反而只会让服务侧报一个**用户看得见**的配置错误，那比看不见的
  /// 错目的地好得多。
  final int? targetSourceId;
}

/// 订阅版本规则里 [key] 的值（字符串或字符串列表）拆成列表。
List<String> videoSubscriptionFilterValues(String rawJson, String key) {
  try {
    final Object? decoded = jsonDecode(rawJson);
    if (decoded is! Map) return const <String>[];
    final Object? value = decoded[key];
    if (value is String) {
      return value.trim().isEmpty ? const <String>[] : <String>[value.trim()];
    }
    if (value is List) {
      return <String>[
        for (final Object? v in value)
          if (v is String && v.trim().isNotEmpty) v.trim(),
      ];
    }
  } on FormatException {
    return const <String>[];
  }
  return const <String>[];
}

/// **纯函数**：把输入框里「逗号 / 顿号分隔」的多个值拆成去重列表。
List<String> splitVideoSubscriptionList(String text) => <String>{
      for (final String part in text.split(RegExp(r'[,，、]')))
        if (part.trim().isNotEmpty) part.trim(),
    }.toList(growable: false);

/// **纯函数**：只改版本规则里「编辑订阅」管得着的四项（字幕组 / 分辨率 / 标题包含 /
/// 标题排除），其余规则（strict、trusted、编码、语言、分类 …）原样保留。空列表 =
/// 去掉该项；单值写字符串、多值写列表（与新建订阅时的形状一致）。
String editVideoSubscriptionFilterJson(
  String rawJson, {
  required List<String> releaseGroups,
  required List<String> resolutions,
  required List<String> titleIncludes,
  required List<String> titleExcludes,
}) {
  Map<String, Object?> filter;
  try {
    final Object? decoded = jsonDecode(rawJson);
    filter = decoded is Map
        ? Map<String, Object?>.from(decoded)
        : <String, Object?>{'strict': true};
  } on FormatException {
    filter = <String, Object?>{'strict': true};
  }
  void put(String key, List<String> values) {
    if (values.isEmpty) {
      filter.remove(key);
    } else {
      filter[key] = values.length == 1 ? values.single : values;
    }
  }

  put('releaseGroup', releaseGroups);
  put('resolution', resolutions);
  put(kVideoSubscriptionTitleIncludeKey, titleIncludes);
  put(kVideoSubscriptionTitleExcludeKey, titleExcludes);
  return jsonEncode(filter);
}

/// 编辑订阅对话框（纯 UI：返回编辑结果，写库由宿主执行）。取消返回 null。
Future<VideoDownloadSubscriptionEdit?> showVideoDownloadSubscriptionEditDialog({
  required BuildContext context,
  required VideoDownloadSubscriptionRow subscription,
  required List<MediaSourceRow> sources,
}) =>
    showAppDialog<VideoDownloadSubscriptionEdit>(
      context: context,
      builder: (BuildContext _) => _SubscriptionEditDialog(
        subscription: subscription,
        sources: sources,
      ),
    );

class _SubscriptionEditDialog extends StatefulWidget {
  const _SubscriptionEditDialog({
    required this.subscription,
    required this.sources,
  });

  final VideoDownloadSubscriptionRow subscription;
  final List<MediaSourceRow> sources;

  @override
  State<_SubscriptionEditDialog> createState() =>
      _SubscriptionEditDialogState();
}

class _SubscriptionEditDialogState extends State<_SubscriptionEditDialog> {
  late final TextEditingController _queryController =
      TextEditingController(text: widget.subscription.searchQuery);
  late final TextEditingController _startAfterController =
      TextEditingController(
    text: widget.subscription.startAfterEpisode?.toString() ?? '',
  );
  late VideoDownloadSubtitlePolicy _subtitlePolicy = VideoDownloadSubtitlePolicy
          .values
          .asNameMap()[widget.subscription.subtitlePolicy] ??
      VideoDownloadSubtitlePolicy.bestEffort;

  /// 当前选中的目标来源。初值就是订阅原本的绑定（哪怕它此刻不可用），绝不回落到
  /// 「列表里的第一个」——见 [VideoDownloadSubscriptionEdit.targetSourceId]。
  late int? _sourceId = widget.subscription.targetSourceId;

  late final TextEditingController _groupController = TextEditingController(
    text: videoSubscriptionFilterValues(
      widget.subscription.filterJson,
      'releaseGroup',
    ).join(', '),
  );
  late final TextEditingController _resolutionController =
      TextEditingController(
    text: videoSubscriptionFilterValues(
      widget.subscription.filterJson,
      'resolution',
    ).join(', '),
  );
  late final TextEditingController _includeController = TextEditingController(
    text: videoSubscriptionFilterValues(
      widget.subscription.filterJson,
      kVideoSubscriptionTitleIncludeKey,
    ).join(', '),
  );
  late final TextEditingController _excludeController = TextEditingController(
    text: videoSubscriptionFilterValues(
      widget.subscription.filterJson,
      kVideoSubscriptionTitleExcludeKey,
    ).join(', '),
  );

  /// 原绑定是否在当前可用列表里。不在时下拉多给一条「(不可用)」占位项，让用户看见
  /// 它绑在哪、也能主动改；不主动改就不写这一列。
  late final bool _boundSourceAvailable = widget.sources.any(
    (MediaSourceRow source) => source.id == widget.subscription.targetSourceId,
  );

  @override
  void dispose() {
    _queryController.dispose();
    _startAfterController.dispose();
    _groupController.dispose();
    _resolutionController.dispose();
    _includeController.dispose();
    _excludeController.dispose();
    super.dispose();
  }

  /// 编辑后的版本规则；与原规则语义相同时为 null（不写这一列）。
  String? get _editedFilterJson {
    final String original = widget.subscription.filterJson;
    final String edited = editVideoSubscriptionFilterJson(
      original,
      releaseGroups: splitVideoSubscriptionList(_groupController.text),
      resolutions: splitVideoSubscriptionList(_resolutionController.text),
      titleIncludes: splitVideoSubscriptionList(_includeController.text),
      titleExcludes: splitVideoSubscriptionList(_excludeController.text),
    );
    final String normalizedOriginal = editVideoSubscriptionFilterJson(
      original,
      releaseGroups: videoSubscriptionFilterValues(original, 'releaseGroup'),
      resolutions: videoSubscriptionFilterValues(original, 'resolution'),
      titleIncludes: videoSubscriptionFilterValues(
        original,
        kVideoSubscriptionTitleIncludeKey,
      ),
      titleExcludes: videoSubscriptionFilterValues(
        original,
        kVideoSubscriptionTitleExcludeKey,
      ),
    );
    return edited == normalizedOriginal ? null : edited;
  }

  /// Nyaa 订阅的服务端硬规则：必须指定字幕组，且有分辨率或画质规则（见订阅服务的
  /// `_SubscriptionFilter.parse`）。只在用户改了规则时才校验——没动的旧订阅照常保存。
  bool get _isNyaa =>
      widget.subscription.resourceProvider.split(':').first == 'nyaa';

  String? get _groupError {
    if (_editedFilterJson == null || !_isNyaa) return null;
    return splitVideoSubscriptionList(_groupController.text).isEmpty
        ? t.subscription_edit_rule_required
        : null;
  }

  String? get _resolutionError {
    if (_editedFilterJson == null || !_isNyaa) return null;
    final bool hasQuality = videoSubscriptionFilterValues(
      widget.subscription.filterJson,
      'quality',
    ).isNotEmpty;
    return splitVideoSubscriptionList(_resolutionController.text).isEmpty &&
            !hasQuality
        ? t.subscription_edit_rule_required
        : null;
  }

  /// 起始集的解析结果：`(ok, value)`。空串合法（= 不限）；其余必须是 >= 0 的整数。
  ///
  /// 不能只用 `int.tryParse`：输入「12話」会 null 掉、把起始集**静默清空**；输入
  /// 「-1」会写库违反 CHECK(start_after_episode IS NULL OR >= 0) 抛异常，而宿主的
  /// _edit 没有 catch —— 对话框已关、界面毫无反应，用户以为保存成功了。
  (bool, int?) get _parsedStartAfter {
    final String raw = _startAfterController.text.trim();
    if (raw.isEmpty) return (true, null);
    final int? value = int.tryParse(raw);
    if (value == null || value < 0) return (false, null);
    return (true, value);
  }

  bool get _canSave =>
      _queryController.text.trim().isNotEmpty &&
      _sourceId != null &&
      _parsedStartAfter.$1 &&
      _groupError == null &&
      _resolutionError == null;

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(
      VideoDownloadSubscriptionEdit(
        searchQuery: _queryController.text.trim(),
        startAfterEpisode: _parsedStartAfter.$2,
        subtitlePolicy: _subtitlePolicy,
        // 没动过就传 null（宿主据此不写这一列）。
        targetSourceId:
            _sourceId == widget.subscription.targetSourceId ? null : _sourceId,
        filterJson: _editedFilterJson,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      title: Text(t.subscription_edit_title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.subscription.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                t.subscription_edit_filter_hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: tokens.spacing.card),
              FushiTextFieldControl(
                key: const ValueKey<String>('subscription-edit-query'),
                controller: _queryController,
                decoration: InputDecoration(
                  labelText: t.video_jimaku_query,
                ),
                maxLines: 1,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: tokens.spacing.gap),
              for (final (Key, TextEditingController, String, String?) field
                  in <(Key, TextEditingController, String, String?)>[
                (
                  const ValueKey<String>('subscription-edit-release-group'),
                  _groupController,
                  t.subscription_edit_release_group,
                  _groupError,
                ),
                (
                  const ValueKey<String>('subscription-edit-resolution'),
                  _resolutionController,
                  t.subscription_edit_resolution,
                  _resolutionError,
                ),
                (
                  const ValueKey<String>('subscription-edit-title-include'),
                  _includeController,
                  t.subscription_edit_title_include,
                  null,
                ),
                (
                  const ValueKey<String>('subscription-edit-title-exclude'),
                  _excludeController,
                  t.subscription_edit_title_exclude,
                  null,
                ),
              ]) ...<Widget>[
                FushiTextFieldControl(
                  key: field.$1,
                  controller: field.$2,
                  decoration: InputDecoration(
                    labelText: field.$3,
                    helperText: t.subscription_edit_list_helper,
                    errorText: field.$4,
                  ),
                  maxLines: 1,
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: tokens.spacing.gap),
              ],
              FushiTextFieldControl(
                key: const ValueKey<String>('subscription-edit-start-after'),
                controller: _startAfterController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.video_jimaku_episode,
                  helperText: t.download_subscription_start_episode(
                    episode: _startAfterController.text.trim().isEmpty
                        ? '1'
                        : _startAfterController.text.trim(),
                  ),
                  // 非法输入直接标错并禁掉保存，而不是静默清空 / 静默写库失败。
                  errorText: _parsedStartAfter.$1
                      ? null
                      : t.download_subscription_start_episode_invalid,
                ),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: tokens.spacing.gap),
              FushiDropdownButtonFormField<VideoDownloadSubtitlePolicy>(
                key: const ValueKey<String>('subscription-edit-subtitle'),
                initialValue: _subtitlePolicy,
                // 与来源下拉同样必须 isExpanded：不给的话 DropdownButton 按**最宽那条
                // 选项**定宽，「包含字幕 · 拒绝」这条在英文下约 1000px，直接把 452 宽的
                // 对话框撑出 RenderFlex 溢出（widget 测试里是硬失败）。
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t.anime_download_include_subs,
                ),
                items: <DropdownMenuItem<VideoDownloadSubtitlePolicy>>[
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.none,
                    child: Text(t.anime_download_no_subs),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.bestEffort,
                    child: Text(t.anime_download_include_subs),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.required,
                    child: Text(
                      '${t.anime_download_include_subs} · '
                      '${t.video_control_reject_required}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (VideoDownloadSubtitlePolicy? value) {
                  if (value != null) setState(() => _subtitlePolicy = value);
                },
              ),
              SizedBox(height: tokens.spacing.gap),
              FushiDropdownButtonFormField<int>(
                key: const ValueKey<String>('subscription-edit-source'),
                initialValue: _sourceId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t.video_download_target_source_title,
                ),
                items: <DropdownMenuItem<int>>[
                  // 原绑定不在可用列表里时（典型：目标库在外置盘，盘拔了就被
                  // existsSync 过滤掉）补一条占位项。少了它，DropdownButtonFormField
                  // 的 initialValue 无对应 item 会抛，于是旧代码退而把选中值改写成
                  // 「列表第一个」——那正是静默改写目标库的来源。留着它，用户既看得见
                  // 当前绑在哪，也可以主动改；不动就不写这一列。
                  if (!_boundSourceAvailable &&
                      widget.subscription.targetSourceId != null)
                    DropdownMenuItem<int>(
                      value: widget.subscription.targetSourceId,
                      child: Text(
                        t.download_subscription_source_unavailable,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  for (final MediaSourceRow source in widget.sources)
                    DropdownMenuItem<int>(
                      value: source.id,
                      child: Text(
                        source.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (int? value) => setState(() => _sourceId = value),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('subscription-edit-save'),
          onPressed: _canSave ? _save : null,
          child: Text(t.dialog_done),
        ),
      ],
    );
  }
}

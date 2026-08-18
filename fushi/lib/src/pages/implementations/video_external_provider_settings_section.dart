import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/torznab_client.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/net/app_user_agent.dart';
import 'package:fushi_core/fushi_core.dart';

@immutable
class ManagedVideoSourceOption {
  const ManagedVideoSourceOption({
    required this.id,
    required this.label,
    required this.rootPath,
  });

  final int id;
  final String label;
  final String rootPath;
}

@immutable
class VideoExternalSettingsSnapshot {
  const VideoExternalSettingsSnapshot({
    this.torznabConfigs = const <TorznabIndexerConfig>[],
    this.openSubtitlesConfig,
    this.jimakuApiKey = '',
    this.pathMappings = const <VideoDownloadBackendPathMappingConfig>[],
    this.managedVideoSources = const <ManagedVideoSourceOption>[],
    this.targetSourceId,
    this.preferredSubtitleLanguage = '',
    this.suggestedBackendProfileId = '',
  });

  final List<TorznabIndexerConfig> torznabConfigs;
  final OpenSubtitlesConfig? openSubtitlesConfig;

  /// Jimaku 的全部配置就是这把 key：非空即注册该来源（`AppModel` 侧门控），
  /// 所以这里不另造 enabled 开关，免得出现「开着但没 key」的假状态。
  final String jimakuApiKey;
  final List<VideoDownloadBackendPathMappingConfig> pathMappings;
  final List<ManagedVideoSourceOption> managedVideoSources;
  final int? targetSourceId;
  final String preferredSubtitleLanguage;
  final String suggestedBackendProfileId;
}

abstract interface class VideoExternalSettingsStore {
  Future<VideoExternalSettingsSnapshot> load();

  Future<void> saveTorznabConfigs(List<TorznabIndexerConfig> configs);

  Future<void> saveOpenSubtitlesConfig(OpenSubtitlesConfig config);

  Future<void> saveJimakuApiKey(String apiKey);

  Future<void> savePathMappings(
    List<VideoDownloadBackendPathMappingConfig> mappings,
  );

  Future<void> saveTargetSourceId(int? sourceId);

  Future<void> savePreferredSubtitleLanguage(String language);
}

class AppVideoExternalSettingsStore implements VideoExternalSettingsStore {
  const AppVideoExternalSettingsStore(this.appModel);

  final AppModel appModel;

  @override
  Future<VideoExternalSettingsSnapshot> load() async {
    final List<MediaSourceRow> rows =
        await appModel.database.getMediaSourcesByKind('video');
    final List<ManagedVideoSourceOption> sources = <ManagedVideoSourceOption>[];
    for (final MediaSourceRow row in rows) {
      if (row.transport != 'local' || !p.isAbsolute(row.rootPath)) continue;
      if (!await Directory(row.rootPath).exists()) continue;
      sources.add(
        ManagedVideoSourceOption(
          id: row.id,
          label: row.label,
          rootPath: row.rootPath,
        ),
      );
    }
    final int? storedTarget = appModel.prefsRepo.videoDownloadTargetSourceId;
    final int? target = sources.any(
      (ManagedVideoSourceOption source) => source.id == storedTarget,
    )
        ? storedTarget
        : null;
    final QbConnectionConfig torrentConfig =
        effectiveTorrentConfig(appModel.qbConnectionConfig);
    String suggestedBackendProfileId = '';
    try {
      suggestedBackendProfileId = buildVideoDownloadBackendIdentity(
        config: torrentConfig,
        resolvedBackend: QbConnectionConfig.backendQbittorrent,
        embeddedInstallationId: '',
      ).profileId;
    } on ArgumentError {
      // An unconfigured qB endpoint has no stable profile identity yet.
    }
    return VideoExternalSettingsSnapshot(
      torznabConfigs: appModel.prefsRepo.videoResourceTorznabConfigs,
      openSubtitlesConfig: appModel.prefsRepo.videoSubtitleOpenSubtitlesConfig,
      jimakuApiKey: appModel.jimakuApiKey,
      pathMappings: appModel.prefsRepo.videoDownloadBackendPathMappings,
      managedVideoSources: sources,
      targetSourceId: target,
      preferredSubtitleLanguage: appModel.jimakuDefaultLanguage,
      suggestedBackendProfileId: suggestedBackendProfileId,
    );
  }

  @override
  Future<void> saveTorznabConfigs(List<TorznabIndexerConfig> configs) async {
    await appModel.prefsRepo.setVideoResourceTorznabConfigs(configs);
    await appModel.reloadVideoDownloadPipelineRuntime();
  }

  @override
  Future<void> saveOpenSubtitlesConfig(OpenSubtitlesConfig config) async {
    await appModel.prefsRepo.setVideoSubtitleOpenSubtitlesConfig(config);
    await appModel.reloadVideoDownloadPipelineRuntime();
  }

  @override
  // `setJimakuApiKey` 自己会重建下载流水线运行时（字幕 registry 按 key 非空注册），
  // 所以这里不再补一次 reload。
  Future<void> saveJimakuApiKey(String apiKey) =>
      appModel.setJimakuApiKey(apiKey.trim());

  @override
  Future<void> savePathMappings(
    List<VideoDownloadBackendPathMappingConfig> mappings,
  ) =>
      appModel.prefsRepo.setVideoDownloadBackendPathMappings(mappings);

  @override
  Future<void> saveTargetSourceId(int? sourceId) =>
      appModel.prefsRepo.setVideoDownloadTargetSourceId(sourceId);

  @override
  Future<void> savePreferredSubtitleLanguage(String language) =>
      appModel.setJimakuDefaultLanguage(language);
}

/// 发现/下载闭环所依赖的设备本地外部配置。
///
/// 密钥字段始终遮罩；端点只有通过 provider 自身的 HTTPS/loopback 安全校验后才写入
/// Preferences。表单错误只显示稳定的本地化提示，不把含密钥的 URL 或异常正文写进
/// snack、日志或诊断导出。
class VideoExternalProviderSettingsSection extends ConsumerStatefulWidget {
  const VideoExternalProviderSettingsSection({
    super.key,
    this.store,
    this.onlySubtitleSources = false,
  });

  /// 测试注入口；生产路径从 [AppModel] 构造设备本地 store。
  final VideoExternalSettingsStore? store;

  /// 只渲染「在线字幕来源」那一节（Jimaku + OpenSubtitles + 默认字幕语言）。
  ///
  /// 字幕来源此前分居两处：Jimaku API key 在设置 → 视频 → 字幕，OpenSubtitles 在
  /// 设置 → 下载 → 外部来源。同一个能力两个家，用户配完一个以为配完了。这里不复制
  /// 一份编辑 UI（那就是第二份真相源），而是让本组件按节可裁，两处渲染同一份实现、
  /// 写同一个 `video_subtitle_opensubtitles_config`。
  ///
  /// 两家 registry 是并列的（`video_subtitle_registry.dart`：动漫搜 Jimaku +
  /// OpenSubtitles，其余只搜 OpenSubtitles），所以两家必须并列出现在同一节里；
  /// 只列一家会让用户以为另一家不存在（用户 2026-08-18 反馈，BUG-1712）。
  final bool onlySubtitleSources;

  @override
  ConsumerState<VideoExternalProviderSettingsSection> createState() =>
      _VideoExternalProviderSettingsSectionState();
}

class _VideoExternalProviderSettingsSectionState
    extends ConsumerState<VideoExternalProviderSettingsSection> {
  VideoExternalSettingsStore? _store;
  bool _loading = true;
  bool _saveFailed = false;
  Future<void> _saveTail = Future<void>.value();
  List<_TorznabDraft> _torznab = <_TorznabDraft>[];
  late _OpenSubtitlesDraft _openSubtitles;
  List<_PathMappingDraft> _mappings = <_PathMappingDraft>[];
  List<ManagedVideoSourceOption> _sources = <ManagedVideoSourceOption>[];
  int? _targetSourceId;
  String _preferredLanguage = '';
  String _jimakuApiKey = '';
  String _suggestedBackendProfileId = '';
  Timer? _torznabSaveDebounce;
  Timer? _openSubtitlesSaveDebounce;
  Timer? _jimakuSaveDebounce;
  Timer? _mappingSaveDebounce;

  @override
  void initState() {
    super.initState();
    _openSubtitles = _OpenSubtitlesDraft.empty();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    final bool flushTorznab = _torznabSaveDebounce?.isActive ?? false;
    final bool flushOpenSubtitles =
        _openSubtitlesSaveDebounce?.isActive ?? false;
    final bool flushJimaku = _jimakuSaveDebounce?.isActive ?? false;
    final bool flushMappings = _mappingSaveDebounce?.isActive ?? false;
    _torznabSaveDebounce?.cancel();
    _openSubtitlesSaveDebounce?.cancel();
    _jimakuSaveDebounce?.cancel();
    _mappingSaveDebounce?.cancel();
    if (flushTorznab) unawaited(_saveTorznabIfValid());
    if (flushOpenSubtitles) unawaited(_saveOpenSubtitlesIfValid());
    if (flushJimaku) unawaited(_saveJimakuApiKey());
    if (flushMappings) unawaited(_saveMappingsIfValid());
    super.dispose();
  }

  Future<void> _load() async {
    final VideoExternalSettingsStore? injected = widget.store;
    final AppModel? appModel = injected == null ? ref.read(appProvider) : null;
    final VideoExternalSettingsStore? store = injected ??
        (appModel!.isPreferencesReady && appModel.isDatabaseReady
            ? AppVideoExternalSettingsStore(appModel)
            : null);
    if (store == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _store = store;
    try {
      final VideoExternalSettingsSnapshot snapshot = await store.load();
      if (!mounted) return;
      setState(() {
        _torznab = snapshot.torznabConfigs
            .map(_TorznabDraft.fromConfig)
            .toList(growable: true);
        _openSubtitles = _OpenSubtitlesDraft.fromConfig(
          snapshot.openSubtitlesConfig,
        );
        _mappings = snapshot.pathMappings
            .map(_PathMappingDraft.fromConfig)
            .toList(growable: true);
        _sources = snapshot.managedVideoSources;
        _targetSourceId = snapshot.targetSourceId;
        _preferredLanguage = snapshot.preferredSubtitleLanguage;
        _jimakuApiKey = snapshot.jimakuApiKey;
        _suggestedBackendProfileId = snapshot.suggestedBackendProfileId;
        _loading = false;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _saveFailed = true;
        });
      }
    }
  }

  Future<void> _save(
    Future<void> Function(VideoExternalSettingsStore) task,
  ) {
    final VideoExternalSettingsStore? store = _store;
    if (store == null) return Future<void>.value();
    _saveTail = _saveTail.then((_) async {
      try {
        await task(store);
        if (mounted && _saveFailed) setState(() => _saveFailed = false);
      } on Object {
        if (mounted) setState(() => _saveFailed = true);
      }
    });
    return _saveTail;
  }

  Future<void> _saveTorznabIfValid() async {
    _torznabSaveDebounce?.cancel();
    _torznabSaveDebounce = null;
    final List<TorznabIndexerConfig> configs = <TorznabIndexerConfig>[];
    for (final _TorznabDraft draft in _torznab) {
      final TorznabIndexerConfig? config = draft.toConfig();
      if (config == null) return;
      configs.add(config);
    }
    await _save(
      (VideoExternalSettingsStore store) => store.saveTorznabConfigs(configs),
    );
  }

  Future<void> _saveOpenSubtitlesIfValid() async {
    _openSubtitlesSaveDebounce?.cancel();
    _openSubtitlesSaveDebounce = null;
    final OpenSubtitlesConfig? config = _openSubtitles.toConfig();
    if (config == null) return;
    await _save(
      (VideoExternalSettingsStore store) =>
          store.saveOpenSubtitlesConfig(config),
    );
  }

  Future<void> _saveMappingsIfValid() async {
    _mappingSaveDebounce?.cancel();
    _mappingSaveDebounce = null;
    final List<VideoDownloadBackendPathMappingConfig> mappings =
        <VideoDownloadBackendPathMappingConfig>[];
    for (final _PathMappingDraft draft in _mappings) {
      final VideoDownloadBackendPathMappingConfig? mapping = draft.toConfig();
      if (mapping == null) return;
      mappings.add(mapping);
    }
    await _save(
      (VideoExternalSettingsStore store) => store.savePathMappings(mappings),
    );
  }

  void _updateTorznab(int index, _TorznabDraft value) {
    setState(() => _torznab[index] = value);
    _torznabSaveDebounce?.cancel();
    _torznabSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_saveTorznabIfValid()),
    );
  }

  void _updateOpenSubtitles(_OpenSubtitlesDraft value) {
    setState(() => _openSubtitles = value);
    _openSubtitlesSaveDebounce?.cancel();
    _openSubtitlesSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_saveOpenSubtitlesIfValid()),
    );
  }

  void _updateJimakuApiKey(String value) {
    _jimakuApiKey = value;
    _jimakuSaveDebounce?.cancel();
    _jimakuSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_saveJimakuApiKey()),
    );
  }

  Future<void> _saveJimakuApiKey() {
    final String apiKey = _jimakuApiKey;
    return _save(
      (VideoExternalSettingsStore store) => store.saveJimakuApiKey(apiKey),
    );
  }

  void _updateMapping(int index, _PathMappingDraft value) {
    setState(() => _mappings[index] = value);
    _mappingSaveDebounce?.cancel();
    _mappingSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_saveMappingsIfValid()),
    );
  }

  Widget _sectionHeading(
    ThemeData theme,
    String title,
    String hint, {
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required Key key,
    required String label,
    required String initialValue,
    required ValueChanged<String> onChanged,
    String? hint,
    String? helper,
    String? errorText,
    bool secret = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextFormField(
            key: key,
            initialValue: initialValue,
            obscureText: secret,
            enableSuggestions: !secret,
            autocorrect: !secret,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              helperText: helper,
              helperMaxLines: 3,
              errorText: errorText,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _torznabCard(ThemeData theme, int index) {
    final _TorznabDraft draft = _torznab[index];
    return FushiCard(
      key: ValueKey<String>('video-torznab-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: SwitchListTile.adaptive(
                  key: ValueKey<String>('video-torznab-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.video_external_enabled),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _updateTorznab(index, draft.copyWith(enabled: value)),
                ),
              ),
              IconButton(
                key: ValueKey<String>('video-torznab-$index-remove'),
                tooltip: t.video_external_remove,
                onPressed: () {
                  setState(() => _torznab.removeAt(index));
                  _saveTorznabIfValid();
                },
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ],
          ),
          _field(
            key: ValueKey<String>('video-torznab-$index-name'),
            label: t.video_torznab_name,
            initialValue: draft.name,
            errorText:
                draft.name.trim().isEmpty ? t.video_external_save_error : null,
            onChanged: (String value) =>
                _updateTorznab(index, draft.copyWith(name: value)),
          ),
          _field(
            key: ValueKey<String>('video-torznab-$index-endpoint'),
            label: t.video_torznab_endpoint,
            initialValue: draft.endpoint,
            helper: t.video_torznab_endpoint_hint,
            keyboardType: TextInputType.url,
            errorText: draft.hasValidEndpoint
                ? null
                : t.video_external_endpoint_invalid,
            onChanged: (String value) =>
                _updateTorznab(index, draft.copyWith(endpoint: value)),
          ),
          _field(
            key: ValueKey<String>('video-torznab-$index-api-key'),
            label: t.video_torznab_api_key,
            initialValue: draft.apiKey,
            secret: true,
            onChanged: (String value) =>
                _updateTorznab(index, draft.copyWith(apiKey: value)),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _field(
                  key: ValueKey<String>('video-torznab-$index-priority'),
                  label: t.video_torznab_priority,
                  initialValue: draft.priority,
                  keyboardType: TextInputType.number,
                  errorText: int.tryParse(draft.priority.trim()) == null
                      ? t.video_external_save_error
                      : null,
                  onChanged: (String value) =>
                      _updateTorznab(index, draft.copyWith(priority: value)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _field(
                  key: ValueKey<String>('video-torznab-$index-categories'),
                  label: t.video_torznab_categories,
                  initialValue: draft.categories,
                  helper: t.video_torznab_categories_hint,
                  keyboardType: TextInputType.number,
                  errorText: draft.categoriesValid
                      ? null
                      : t.video_external_categories_invalid,
                  onChanged: (String value) => _updateTorznab(
                    index,
                    draft.copyWith(categories: value),
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            key: ValueKey<String>('video-torznab-$index-insecure-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.video_external_insecure_http),
            subtitle: Text(t.video_external_insecure_http_hint),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) => _updateTorznab(
              index,
              draft.copyWith(allowInsecureHttp: value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _openSubtitlesFields() {
    final _OpenSubtitlesDraft draft = _openSubtitles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile.adaptive(
          key: const ValueKey<String>('video-opensubtitles-enabled'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.video_external_enabled),
          value: draft.enabled,
          onChanged: (bool value) =>
              _updateOpenSubtitles(draft.copyWith(enabled: value)),
        ),
        _field(
          key: const ValueKey<String>('video-opensubtitles-endpoint'),
          label: t.video_opensubtitles_endpoint,
          initialValue: draft.endpoint,
          helper: t.video_torznab_endpoint_hint,
          keyboardType: TextInputType.url,
          errorText:
              draft.hasValidEndpoint ? null : t.video_external_endpoint_invalid,
          onChanged: (String value) =>
              _updateOpenSubtitles(draft.copyWith(endpoint: value)),
        ),
        _field(
          key: const ValueKey<String>('video-opensubtitles-api-key'),
          label: t.video_external_api_key,
          initialValue: draft.apiKey,
          secret: true,
          onChanged: (String value) =>
              _updateOpenSubtitles(draft.copyWith(apiKey: value)),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _field(
                key: const ValueKey<String>('video-opensubtitles-username'),
                label: t.video_external_username_optional,
                initialValue: draft.username,
                onChanged: (String value) =>
                    _updateOpenSubtitles(draft.copyWith(username: value)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _field(
                key: const ValueKey<String>('video-opensubtitles-password'),
                label: t.video_external_password_optional,
                initialValue: draft.password,
                secret: true,
                onChanged: (String value) =>
                    _updateOpenSubtitles(draft.copyWith(password: value)),
              ),
            ),
          ],
        ),
        _field(
          key: const ValueKey<String>('video-opensubtitles-user-agent'),
          label: t.video_opensubtitles_user_agent,
          initialValue: draft.userAgent,
          errorText: draft.userAgent.trim().isEmpty
              ? t.video_external_save_error
              : null,
          onChanged: (String value) =>
              _updateOpenSubtitles(draft.copyWith(userAgent: value)),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey<String>('video-opensubtitles-insecure-http'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.video_external_insecure_http),
          subtitle: Text(t.video_external_insecure_http_hint),
          value: draft.allowInsecureHttp,
          onChanged: (bool value) => _updateOpenSubtitles(
            draft.copyWith(allowInsecureHttp: value),
          ),
        ),
      ],
    );
  }

  /// Jimaku：全部配置只有一把 key（非空即启用）。
  ///
  /// 这里不 setState —— 输入框自己持有文本，重建只会把光标弹回去。
  Widget _jimakuFields() {
    return _field(
      key: const ValueKey<String>('video-jimaku-api-key'),
      label: t.video_jimaku_api_key,
      initialValue: _jimakuApiKey,
      helper: t.video_jimaku_api_key_hint,
      secret: true,
      onChanged: _updateJimakuApiKey,
    );
  }

  /// 默认字幕语言：两家 provider 共用的**一个**偏好（存量键名
  /// `jimaku_default_language` 冻结不追改），所以它属于「字幕来源」这一节，
  /// 而不是某一家的卡片内字段——此前它长在 OpenSubtitles 块里，读起来像
  /// 「OpenSubtitles 的首选语言」，实际连 Jimaku 一起管。
  Widget _subtitleLanguageField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: DropdownButtonFormField<String>(
            key: const ValueKey<String>('video-subtitle-default-language'),
            initialValue: _preferredLanguage,
            // `isExpanded` + 逐项省略：不加的话 DropdownButton 按**内容固有宽度**
            // 排版，长标签在 360px 紧凑布局里直接横向溢出（`compact layout has no
            // horizontal overflow` 会红）。这里的选项以前全是 `日本語` / `中文`
            // 这类两三字的短标签，才一直没暴露；`''` 从「全部」改成「跟随视频语言」
            // 后就撞上了——而且这不是中文特有：17 份 i18n 里未翻译的那些落的是英文
            // 原串 `Follow video language`，比中文还长。所以修的是约束，不是文案。
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t.video_setting_jimaku_default_language,
              helperText: t.video_setting_jimaku_default_language_hint,
              helperMaxLines: 3,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: '',
                // 与设置页那份同一语义：`''` = 跟随视频语言，不是「全部」。
                child: Text(
                  t.video_jimaku_language_follow_video,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final String language in kJimakuLanguageCodes)
                DropdownMenuItem<String>(
                  value: language,
                  child: Text(
                    jimakuLanguageLabel(language),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (String? value) {
              final String language = value ?? '';
              setState(() => _preferredLanguage = language);
              _save(
                (VideoExternalSettingsStore store) =>
                    store.savePreferredSubtitleLanguage(language),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 两家在线字幕来源 + 共用的默认语言。设置 → 视频 → 字幕与设置 → 下载 →
  /// 外部资源与字幕来源渲染的是同一份。
  List<Widget> _subtitleSourceBlocks(ThemeData theme) {
    return <Widget>[
      _sectionHeading(
        theme,
        // 品牌名，不进 i18n（同设置页 TMDB 的处理）。
        'Jimaku',
        t.video_jimaku_scope_hint,
        icon: Icons.subtitles_outlined,
      ),
      _jimakuFields(),
      _sectionHeading(
        theme,
        t.video_opensubtitles_settings_title,
        t.video_opensubtitles_settings_hint,
        icon: Icons.subtitles_outlined,
      ),
      _openSubtitlesFields(),
      _subtitleLanguageField(),
    ];
  }

  /// 随应用内置、零配置的资源来源。
  ///
  /// 用户打开这一区只看到「Torznab（空）」，合理推论是「这个 app 自己没有任何
  /// 来源」——但动漫其实一直在搜内置 Nyaa（`video_resource_registry.dart` 的
  /// `anime && provider.id == 'nyaa'`）。内置项不落 pref、没有可编辑字段，所以
  /// 这里是只读一行：告诉用户它存在、覆盖到哪，而不是造一个假的配置卡片。
  Widget _builtinSourcesBlock(ThemeData theme) {
    return Column(
      key: const ValueKey<String>('video-builtin-sources'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _sectionHeading(
          theme,
          t.video_builtin_sources_title,
          t.video_builtin_sources_hint,
          icon: Icons.verified_outlined,
        ),
        FushiListItem(
          key: const ValueKey<String>('video-builtin-source-nyaa'),
          leading: const Icon(Icons.public_outlined),
          title: const Text('Nyaa'),
          subtitle: Text(t.video_builtin_nyaa_hint),
          subtitleMaxLines: 3,
        ),
      ],
    );
  }

  Widget _mappingCard(int index) {
    final _PathMappingDraft draft = _mappings[index];
    return FushiCard(
      key: ValueKey<String>('video-path-mapping-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: ValueKey<String>('video-path-mapping-$index-remove'),
              tooltip: t.video_external_remove,
              onPressed: () {
                setState(() => _mappings.removeAt(index));
                _saveMappingsIfValid();
              },
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ),
          _field(
            key: ValueKey<String>('video-path-mapping-$index-profile'),
            label: t.video_download_backend_profile_id,
            initialValue: draft.backendProfileId,
            errorText: draft.backendProfileId.trim().isEmpty
                ? t.video_download_path_mapping_invalid
                : null,
            onChanged: (String value) => _updateMapping(
              index,
              draft.copyWith(backendProfileId: value),
            ),
          ),
          _field(
            key: ValueKey<String>('video-path-mapping-$index-remote'),
            label: t.video_download_remote_root,
            initialValue: draft.remoteRoot,
            errorText: draft.remoteRoot.trim().isEmpty
                ? t.video_download_path_mapping_invalid
                : null,
            onChanged: (String value) => _updateMapping(
              index,
              draft.copyWith(remoteRoot: value),
            ),
          ),
          _field(
            key: ValueKey<String>('video-path-mapping-$index-local'),
            label: t.video_download_local_root,
            initialValue: draft.localRoot,
            errorText: p.isAbsolute(draft.localRoot.trim())
                ? null
                : t.video_download_path_mapping_invalid,
            onChanged: (String value) => _updateMapping(
              index,
              draft.copyWith(localRoot: value),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_store == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    if (widget.onlySubtitleSources) {
      return Column(
        key: const ValueKey<String>('video-external-subtitle-sources'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_saveFailed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.video_external_save_error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ..._subtitleSourceBlocks(theme),
        ],
      );
    }
    return Column(
      key: const ValueKey<String>('video-external-provider-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Divider(height: 32),
        Text(
          t.video_external_settings_section,
          style: theme.textTheme.titleMedium,
        ),
        if (_saveFailed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.video_external_save_error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        _builtinSourcesBlock(theme),
        const Divider(height: 32),
        _sectionHeading(
          theme,
          t.video_torznab_settings_title,
          t.video_torznab_settings_hint,
          icon: Icons.travel_explore_outlined,
        ),
        for (int index = 0; index < _torznab.length; index++)
          _torznabCard(theme, index),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('video-torznab-add'),
            onPressed: () => setState(
              () => _torznab.add(_TorznabDraft.empty(_newDraftId('torznab'))),
            ),
            icon: const Icon(Icons.add),
            label: Text(t.video_torznab_add),
          ),
        ),
        const Divider(height: 32),
        ..._subtitleSourceBlocks(theme),
        const Divider(height: 32),
        _sectionHeading(
          theme,
          t.video_download_path_mappings_title,
          t.video_download_path_mappings_hint,
          icon: Icons.route_outlined,
        ),
        for (int index = 0; index < _mappings.length; index++)
          _mappingCard(index),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('video-path-mapping-add'),
            onPressed: () => setState(
              () => _mappings.add(_PathMappingDraft.empty(
                _newDraftId('mapping'),
                suggestedBackendProfileId: _suggestedBackendProfileId,
              )),
            ),
            icon: const Icon(Icons.add),
            label: Text(t.video_download_path_mapping_add),
          ),
        ),
        const Divider(height: 32),
        _sectionHeading(
          theme,
          t.video_download_target_source_title,
          t.video_download_target_source_hint,
          icon: Icons.video_library_outlined,
        ),
        if (_sources.isEmpty)
          Text(
            t.video_download_target_source_empty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          DropdownButtonFormField<int>(
            key: ValueKey<String>(
              'video-target-source-${_targetSourceId ?? 'none'}',
            ),
            initialValue: _targetSourceId ?? 0,
            decoration: InputDecoration(
              labelText: t.video_download_target_source_none,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            isExpanded: true,
            items: <DropdownMenuItem<int>>[
              DropdownMenuItem<int>(
                value: 0,
                child: Text(t.video_download_target_source_none),
              ),
              for (final ManagedVideoSourceOption source in _sources)
                DropdownMenuItem<int>(
                  value: source.id,
                  child: Text(
                    '${source.label} — ${source.rootPath}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (int? sourceId) {
              final int? selected = sourceId == 0 ? null : sourceId;
              setState(() => _targetSourceId = selected);
              _save(
                (VideoExternalSettingsStore store) =>
                    store.saveTargetSourceId(selected),
              );
            },
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

String _newDraftId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}';

@immutable
class _TorznabDraft {
  const _TorznabDraft({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.apiKey,
    required this.enabled,
    required this.priority,
    required this.categories,
    required this.allowInsecureHttp,
  });

  factory _TorznabDraft.empty(String id) => _TorznabDraft(
        id: id,
        name: '',
        endpoint: '',
        apiKey: '',
        enabled: true,
        priority: '100',
        categories: '',
        allowInsecureHttp: false,
      );

  factory _TorznabDraft.fromConfig(TorznabIndexerConfig config) =>
      _TorznabDraft(
        id: config.id,
        name: config.name,
        endpoint: config.endpoint.toString(),
        apiKey: config.apiKey,
        enabled: config.enabled,
        priority: '${config.priority}',
        categories: config.categories.join(','),
        allowInsecureHttp: config.allowInsecureHttp,
      );

  final String id;
  final String name;
  final String endpoint;
  final String apiKey;
  final bool enabled;
  final String priority;
  final String categories;
  final bool allowInsecureHttp;

  List<int>? get parsedCategories {
    if (categories.trim().isEmpty) return const <int>[];
    final List<int> values = <int>[];
    for (final String raw in categories.split(',')) {
      final int? value = int.tryParse(raw.trim());
      if (value == null || value < 0) return null;
      values.add(value);
    }
    return values;
  }

  bool get categoriesValid => parsedCategories != null;

  bool get hasValidEndpoint => _parseEndpoint() != null;

  TorznabEndpointParts? _parseEndpoint() {
    try {
      final Uri raw = Uri.parse(endpoint.trim());
      if (raw.hasQuery || raw.userInfo.isNotEmpty || raw.hasFragment) {
        return null;
      }
      final TorznabEndpointParts parts = splitTorznabEndpointCredentials(
        endpoint,
        apiKey: apiKey,
      );
      TorznabIndexerConfig(
        id: id,
        name: name,
        endpoint: parts.endpoint,
        apiKey: parts.apiKey,
        allowInsecureHttp: allowInsecureHttp,
      );
      return parts;
    } on Object {
      return null;
    }
  }

  TorznabIndexerConfig? toConfig() {
    final TorznabEndpointParts? parts = _parseEndpoint();
    final int? parsedPriority = int.tryParse(priority.trim());
    final List<int>? parsed = parsedCategories;
    if (name.trim().isEmpty ||
        parts == null ||
        parsedPriority == null ||
        parsed == null) {
      return null;
    }
    try {
      return TorznabIndexerConfig(
        id: id,
        name: name.trim(),
        endpoint: parts.endpoint,
        apiKey: parts.apiKey,
        enabled: enabled,
        priority: parsedPriority,
        categories: parsed,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on Object {
      return null;
    }
  }

  _TorznabDraft copyWith({
    String? name,
    String? endpoint,
    String? apiKey,
    bool? enabled,
    String? priority,
    String? categories,
    bool? allowInsecureHttp,
  }) =>
      _TorznabDraft(
        id: id,
        name: name ?? this.name,
        endpoint: endpoint ?? this.endpoint,
        apiKey: apiKey ?? this.apiKey,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
        categories: categories ?? this.categories,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );
}

@immutable
class _OpenSubtitlesDraft {
  const _OpenSubtitlesDraft({
    required this.endpoint,
    required this.apiKey,
    required this.username,
    required this.password,
    required this.userAgent,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory _OpenSubtitlesDraft.empty() => _OpenSubtitlesDraft(
        endpoint: 'https://api.opensubtitles.com/api/v1',
        apiKey: '',
        username: '',
        password: '',
        userAgent: fushiUserAgent('opensubtitles'),
        enabled: false,
        allowInsecureHttp: false,
      );

  factory _OpenSubtitlesDraft.fromConfig(OpenSubtitlesConfig? config) =>
      config == null
          ? _OpenSubtitlesDraft.empty()
          : _OpenSubtitlesDraft(
              endpoint: config.baseUrl.toString(),
              apiKey: config.apiKey,
              username: config.username ?? '',
              password: config.password ?? '',
              userAgent: config.userAgent,
              enabled: config.enabled,
              allowInsecureHttp: config.allowInsecureHttp,
            );

  final String endpoint;
  final String apiKey;
  final String username;
  final String password;
  final String userAgent;
  final bool enabled;
  final bool allowInsecureHttp;

  bool get hasValidEndpoint => toConfig() != null;

  OpenSubtitlesConfig? toConfig() {
    final Uri? parsed = Uri.tryParse(endpoint.trim());
    if (parsed == null || userAgent.trim().isEmpty) return null;
    try {
      return OpenSubtitlesConfig(
        apiKey: apiKey,
        username: username.trim().isEmpty ? null : username.trim(),
        password: password.isEmpty ? null : password,
        userAgent: userAgent.trim(),
        baseUrl: parsed,
        enabled: enabled,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on Object {
      return null;
    }
  }

  _OpenSubtitlesDraft copyWith({
    String? endpoint,
    String? apiKey,
    String? username,
    String? password,
    String? userAgent,
    bool? enabled,
    bool? allowInsecureHttp,
  }) =>
      _OpenSubtitlesDraft(
        endpoint: endpoint ?? this.endpoint,
        apiKey: apiKey ?? this.apiKey,
        username: username ?? this.username,
        password: password ?? this.password,
        userAgent: userAgent ?? this.userAgent,
        enabled: enabled ?? this.enabled,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );
}

@immutable
class _PathMappingDraft {
  const _PathMappingDraft({
    required this.id,
    required this.backendProfileId,
    required this.remoteRoot,
    required this.localRoot,
  });

  factory _PathMappingDraft.empty(
    String id, {
    String suggestedBackendProfileId = '',
  }) =>
      _PathMappingDraft(
        id: id,
        backendProfileId: suggestedBackendProfileId,
        remoteRoot: '',
        localRoot: '',
      );

  factory _PathMappingDraft.fromConfig(
    VideoDownloadBackendPathMappingConfig config,
  ) =>
      _PathMappingDraft(
        id: '${config.backendProfileId}:${config.remoteRoot}',
        backendProfileId: config.backendProfileId,
        remoteRoot: config.remoteRoot,
        localRoot: config.localRoot,
      );

  final String id;
  final String backendProfileId;
  final String remoteRoot;
  final String localRoot;

  VideoDownloadBackendPathMappingConfig? toConfig() {
    final VideoDownloadBackendPathMappingConfig value =
        VideoDownloadBackendPathMappingConfig(
      backendProfileId: backendProfileId.trim(),
      remoteRoot: remoteRoot.trim(),
      localRoot: localRoot.trim(),
    );
    return value.isValid && p.isAbsolute(value.localRoot) ? value : null;
  }

  _PathMappingDraft copyWith({
    String? backendProfileId,
    String? remoteRoot,
    String? localRoot,
  }) =>
      _PathMappingDraft(
        id: id,
        backendProfileId: backendProfileId ?? this.backendProfileId,
        remoteRoot: remoteRoot ?? this.remoteRoot,
        localRoot: localRoot ?? this.localRoot,
      );
}

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
import 'package:hibiki/src/media/tracking/media_tracking_labels.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki/src/media/tracking/media_tracking_service.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:url_launcher/url_launcher.dart';

class MediaTrackingSettingsBody extends StatefulWidget {
  const MediaTrackingSettingsBody({
    required this.appModel,
    super.key,
  });

  final AppModel appModel;

  @override
  State<MediaTrackingSettingsBody> createState() =>
      _MediaTrackingSettingsBodyState();
}

class _MediaTrackingSettingsBodyState extends State<MediaTrackingSettingsBody> {
  late final MediaTrackingRepository _repository =
      MediaTrackingRepository(widget.appModel.database);
  late final TextEditingController _tokenController = TextEditingController(
    text: widget.appModel.mediaTrackingService.accessToken,
  );

  List<MediaTrackingMappingRow> _mappings = const <MediaTrackingMappingRow>[];
  int _pending = 0;

  /// 最近一次载入的状态快照（上次同步时刻/结果、失败原因）。
  MediaTrackingStatus? _status;

  /// 已连接账号名。取自持久化偏好而非仅本次会话的连接结果——否则重开设置页
  /// 就只剩一个填了令牌的输入框，用户无法确认连的是哪个账号。
  String? _connectedAccount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final String stored = widget.appModel.mediaTrackingService.accountName;
    if (stored.isNotEmpty) _connectedAccount = stored;
    _reload();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    // 映射列表 / 待办数 / 上次同步结果 / 失败原因统一走服务层快照，与首页卡片同源
    // （含「隐藏 bookChapter 伴随映射」这条口径），不再各查一遍各滤一遍。
    final MediaTrackingStatus status =
        await widget.appModel.mediaTrackingService.loadStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _mappings = status.mappings;
      _pending = status.pending;
    });
  }

  Future<void> _connect() async {
    final String token = _tokenController.text.trim();
    if (token.isEmpty) {
      _message(t.media_tracking_token_required);
      return;
    }
    setState(() => _busy = true);
    try {
      // 校验 + 落令牌 + 记账号名是一次原子的「连接」，交给服务层，避免设置页与
      // 首页各写一份半状态。
      final BangumiUser user =
          await widget.appModel.mediaTrackingService.connect(token);
      if (!mounted) return;
      setState(() => _connectedAccount =
          user.nickname.isEmpty ? user.username : user.nickname);
      _message(t.media_tracking_sync_success);
      await _sync();
    } catch (_) {
      _message(t.media_tracking_sync_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    if (!widget.appModel.mediaTrackingService.isConfigured) {
      _message(t.media_tracking_token_required);
      return;
    }
    setState(() => _busy = true);
    final MediaTrackingSyncResult result =
        await widget.appModel.mediaTrackingService.syncNow(force: true);
    if (!mounted) return;
    _message(result.isSuccess
        ? t.media_tracking_sync_success
        : t.media_tracking_sync_failed);
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addMapping() async {
    if (!widget.appModel.mediaTrackingService.isConfigured) {
      _message(t.media_tracking_token_required);
      return;
    }
    final bool? saved = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => _AddMappingDialog(
        database: widget.appModel.database,
        repository: _repository,
        service: widget.appModel.mediaTrackingService,
      ),
    );
    if (saved ?? false) {
      _message(t.media_tracking_saved);
      await _reload();
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final MediaTrackingStatus? status = _status;
    final Map<int, MediaTrackingFailure> failureByMappingId =
        status?.failureByMappingId ?? const <int, MediaTrackingFailure>{};
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AdaptiveSettingsSection(
          title: t.media_tracking_account,
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.media_tracking_access_token,
              subtitle: t.media_tracking_access_token_hint,
              controlBelow: true,
              trailing: TextField(
                controller: _tokenController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: t.media_tracking_access_token_hint,
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => launchUrl(
                      Uri.parse(BangumiApiClient.accessTokenUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
              ),
            ),
            AdaptiveSettingsRow(
              title: t.media_tracking_signup,
              trailing: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(BangumiApiClient.signupUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.person_add_alt),
                label: Text(t.media_tracking_signup),
              ),
            ),
            if (_connectedAccount != null)
              AdaptiveSettingsRow(
                title: t.media_tracking_connected_as,
                trailing: Text(_connectedAccount!),
              ),
            AdaptiveSettingsRow(
              title: t.media_tracking_connect,
              trailing: _busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: _connect,
                      icon: const Icon(Icons.link),
                      label: Text(t.media_tracking_connect),
                    ),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.media_tracking_mappings,
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.media_tracking_pending,
              trailing: Text('$_pending'),
            ),
            // 「上次同步」+ 失败原因：同步成功即删 outbox 行，没有这两行的话
            // 「跑过但没有待办」与「从没跑过」在 UI 上完全同形。
            AdaptiveSettingsRow(
              title: t.media_tracking_last_sync,
              trailing: Text(
                status == null
                    ? '—'
                    : trackingLastSyncLabel(status, DateTime.now()),
              ),
            ),
            if (status != null && status.unauthorized)
              AdaptiveSettingsRow(
                title: t.media_tracking_unauthorized,
                titleMaxLines: 4,
                icon: Icons.error_outline,
                showIcon: true,
              ),
            AdaptiveSettingsRow(
              title: t.media_tracking_sync_now,
              trailing: FilledButton.tonalIcon(
                onPressed: _busy ? null : _sync,
                icon: const Icon(Icons.sync),
                label: Text(t.media_tracking_sync_now),
              ),
            ),
            AdaptiveSettingsRow(
              title: t.media_tracking_add_mapping,
              trailing: FilledButton.icon(
                onPressed: _busy ? null : _addMapping,
                icon: const Icon(Icons.add_link),
                label: Text(t.media_tracking_add_mapping),
              ),
            ),
            if (_mappings.isEmpty)
              AdaptiveSettingsRow(
                title: t.media_tracking_no_mappings,
                titleMaxLines: 4,
              ),
            // 失败原因挂在对应条目行的副标题上（与首页卡同口径），不另开一段把
            // 标题重复一遍。
            for (final MediaTrackingMappingRow mapping in _mappings)
              AdaptiveSettingsRow(
                title: mapping.mediaTitle,
                subtitle: <String>[
                  '${trackingMappingSubtitle(mapping)} '
                      '+${mapping.progressOffset}',
                  if (failureByMappingId[mapping.id]
                      case final MediaTrackingFailure failure)
                    '${t.media_tracking_last_error}: ${failure.error}',
                ].join('\n'),
                subtitleMaxLines: 4,
                titleMaxLines: 3,
                icon: Icons.sync_problem_outlined,
                showIcon: failureByMappingId.containsKey(mapping.id),
                trailing: IconButton(
                  tooltip: t.media_tracking_delete_mapping,
                  onPressed: () async {
                    await _repository.deleteMapping(mapping.id);
                    await _reload();
                  },
                  icon: const Icon(Icons.link_off),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LocalTrackingTarget {
  const _LocalTrackingTarget({
    required this.type,
    required this.key,
    required this.title,
  });

  final TrackingMediaType type;
  final String key;
  final String title;

  bool get isBook => type == TrackingMediaType.book;

  bool get isGame => type == TrackingMediaType.game;
}

class _AddMappingDialog extends StatefulWidget {
  const _AddMappingDialog({
    required this.database,
    required this.repository,
    required this.service,
  });

  final HibikiDatabase database;
  final MediaTrackingRepository repository;
  final MediaTrackingService service;

  @override
  State<_AddMappingDialog> createState() => _AddMappingDialogState();
}

class _AddMappingDialogState extends State<_AddMappingDialog> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _offsetController =
      TextEditingController(text: '1');

  List<_LocalTrackingTarget> _targets = const <_LocalTrackingTarget>[];
  List<BangumiSubject> _results = const <BangumiSubject>[];
  _LocalTrackingTarget? _target;
  TrackingKind _kind = TrackingKind.anime;
  TrackingProgressMode _mode = TrackingProgressMode.episode;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _offsetController.dispose();
    super.dispose();
  }

  Future<void> _loadTargets() async {
    final List<EpubBookRow> books = await widget.database.getAllEpubBooks();
    final List<VideoBookRow> videos = await widget.database.allVideoBooks();
    final List<GalgameRow> games = await widget.database.getAllGalgames();
    final List<MediaCollectionRow> collections =
        await widget.database.getAllMediaCollections();
    final List<MediaCollectionItemRow> members =
        await widget.database.getAllCollectionItems();
    final Set<int> videoPlaylists = members
        .where((MediaCollectionItemRow row) => row.mediaType == 'video')
        .map((MediaCollectionItemRow row) => row.collectionId)
        .toSet();
    final List<_LocalTrackingTarget> targets = <_LocalTrackingTarget>[
      for (final MediaCollectionRow collection in collections)
        if (collection.collectionType == 'playlist' &&
            videoPlaylists.contains(collection.id))
          _LocalTrackingTarget(
            type: TrackingMediaType.videoCollection,
            key: collection.id.toString(),
            title: collection.name,
          ),
      for (final VideoBookRow video in videos)
        _LocalTrackingTarget(
          type: TrackingMediaType.video,
          key: video.bookUid,
          title: video.title,
        ),
      for (final EpubBookRow book in books)
        _LocalTrackingTarget(
          type: TrackingMediaType.book,
          key: book.bookKey,
          title: book.title,
        ),
      for (final GalgameRow game in games)
        _LocalTrackingTarget(
          type: TrackingMediaType.game,
          key: game.id,
          title: game.name,
        ),
    ];
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _busy = false;
    });
    if (targets.isNotEmpty) _selectTarget(targets.first);
  }

  void _selectTarget(_LocalTrackingTarget target) {
    setState(() {
      _target = target;
      _kind = switch (target.type) {
        TrackingMediaType.game => TrackingKind.game,
        TrackingMediaType.book => TrackingKind.novel,
        _ => TrackingKind.anime,
      };
      _mode = switch (target.type) {
        TrackingMediaType.game => TrackingProgressMode.status,
        TrackingMediaType.book => TrackingProgressMode.volume,
        _ => TrackingProgressMode.episode,
      };
      _offsetController.text = '1';
      _searchController.text = target.title;
      _results = const <BangumiSubject>[];
    });
  }

  Future<void> _search() async {
    if (_target == null || _searchController.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final List<BangumiSubject> results = await widget.service.searchSubjects(
        keyword: _searchController.text,
        kind: _kind,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(BangumiSubject subject) async {
    final _LocalTrackingTarget? target = _target;
    if (target == null) return;
    // status 模式下 outbox.progress 存的是收藏 type 本身，任何非零 offset 都会把
    // 它算成另一个状态，必须钉死为 0。
    final int offset = _mode == TrackingProgressMode.status
        ? 0
        : (int.tryParse(_offsetController.text) ??
            (_mode == TrackingProgressMode.chapter ? 0 : 1));
    await widget.repository.saveMapping(
      mediaType: target.type,
      mediaKey: target.key,
      mediaTitle: target.title,
      kind: _kind,
      subjectId: subject.id,
      subjectName: subject.displayName,
      progressMode: _mode,
      progressOffset: offset.clamp(0, 100000),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.media_tracking_add_mapping),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButtonFormField<_LocalTrackingTarget>(
                initialValue: _target,
                decoration:
                    InputDecoration(labelText: t.media_tracking_local_item),
                items: <DropdownMenuItem<_LocalTrackingTarget>>[
                  for (final _LocalTrackingTarget target in _targets)
                    DropdownMenuItem<_LocalTrackingTarget>(
                      value: target,
                      child: Text(
                        target.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _selectTarget(value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TrackingKind>(
                initialValue: _kind,
                decoration: InputDecoration(labelText: t.media_tracking_kind),
                items: <DropdownMenuItem<TrackingKind>>[
                  if (_target?.isGame ?? false)
                    DropdownMenuItem<TrackingKind>(
                      value: TrackingKind.game,
                      child: Text(t.media_tracking_game),
                    ),
                  if (!(_target?.isBook ?? false) &&
                      !(_target?.isGame ?? false))
                    DropdownMenuItem<TrackingKind>(
                      value: TrackingKind.anime,
                      child: Text(t.media_tracking_anime),
                    ),
                  if (_target?.isBook ??
                      false) ...<DropdownMenuItem<TrackingKind>>[
                    DropdownMenuItem<TrackingKind>(
                      value: TrackingKind.novel,
                      child: Text(t.media_tracking_novel),
                    ),
                    DropdownMenuItem<TrackingKind>(
                      value: TrackingKind.manga,
                      child: Text(t.media_tracking_manga),
                    ),
                  ],
                ],
                onChanged: (TrackingKind? value) {
                  if (value != null) setState(() => _kind = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TrackingProgressMode>(
                initialValue: _mode,
                decoration: InputDecoration(
                  labelText: t.media_tracking_progress_mode,
                ),
                items: <DropdownMenuItem<TrackingProgressMode>>[
                  if (_target?.isGame ?? false)
                    DropdownMenuItem<TrackingProgressMode>(
                      value: TrackingProgressMode.status,
                      child: Text(t.media_tracking_status),
                    ),
                  if (!(_target?.isBook ?? false) &&
                      !(_target?.isGame ?? false))
                    DropdownMenuItem<TrackingProgressMode>(
                      value: TrackingProgressMode.episode,
                      child: Text(t.media_tracking_episode),
                    ),
                  if (_target?.isBook ??
                      false) ...<DropdownMenuItem<TrackingProgressMode>>[
                    DropdownMenuItem<TrackingProgressMode>(
                      value: TrackingProgressMode.chapter,
                      child: Text(t.media_tracking_chapter),
                    ),
                    DropdownMenuItem<TrackingProgressMode>(
                      value: TrackingProgressMode.volume,
                      child: Text(t.media_tracking_volume),
                    ),
                  ],
                ],
                onChanged: (TrackingProgressMode? value) {
                  if (value == null) return;
                  setState(() {
                    _mode = value;
                    _offsetController.text =
                        value == TrackingProgressMode.chapter ||
                                value == TrackingProgressMode.status
                            ? '0'
                            : '1';
                  });
                },
              ),
              // 收藏状态模式没有进度可偏移（Bangumi 游戏条目无话数/卷数），
              // 保留输入框只会让用户填出一个被忽略的值。
              if (_mode != TrackingProgressMode.status) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  controller: _offsetController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.media_tracking_progress_offset,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: t.media_tracking_search,
                  suffixIcon: IconButton(
                    onPressed: _busy ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              if (!_busy && _error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!_busy && _results.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    t.media_tracking_search_results,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final BangumiSubject subject in _results)
                  HibikiListItem(
                    density: HibikiListDensity.compact,
                    padding: EdgeInsets.zero,
                    leading: subject.coverUrl == null
                        ? const Icon(Icons.auto_stories_outlined)
                        : Image.network(
                            subject.coverUrl!,
                            width: 42,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                    title: Text(subject.displayName),
                    subtitle: Text(
                      <String>[
                        if (subject.secondaryName.isNotEmpty)
                          subject.secondaryName,
                        '#${subject.id}',
                      ].join(' · '),
                    ),
                    onTap: () => _save(subject),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
      ],
    );
  }
}

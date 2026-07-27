import 'package:flutter/material.dart';
import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
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
  String? _connectedAccount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final List<MediaTrackingMappingRow> mappings =
        await _repository.listMappings();
    final int pending = await _repository.pendingCount();
    if (!mounted) return;
    setState(() {
      _mappings = mappings
          .where(
            (mapping) =>
                mapping.mediaType != TrackingMediaType.bookChapter.value,
          )
          .toList(growable: false);
      _pending = pending;
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
      final BangumiUser user =
          await widget.appModel.mediaTrackingService.validateAccessToken(token);
      await widget.appModel.mediaTrackingService.setAccessToken(token);
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
            for (final MediaTrackingMappingRow mapping in _mappings)
              AdaptiveSettingsRow(
                title: mapping.mediaTitle,
                subtitle: '${_kindLabel(mapping.kind)} · '
                    '${mapping.subjectName} · '
                    '${_modeLabel(mapping.progressMode)} '
                    '+${mapping.progressOffset}',
                titleMaxLines: 3,
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
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.media_tracking_bookmeter_note,
              titleMaxLines: 5,
              icon: Icons.info_outline,
              showIcon: true,
            ),
          ],
        ),
      ],
    );
  }
}

String _kindLabel(String value) {
  switch (value) {
    case 'anime':
      return t.media_tracking_anime;
    case 'manga':
      return t.media_tracking_manga;
    default:
      return t.media_tracking_novel;
  }
}

String _modeLabel(String value) {
  switch (value) {
    case 'episode':
      return t.media_tracking_episode;
    case 'volume':
      return t.media_tracking_volume;
    default:
      return t.media_tracking_chapter;
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
      _kind = target.isBook ? TrackingKind.novel : TrackingKind.anime;
      _mode = target.isBook
          ? TrackingProgressMode.volume
          : TrackingProgressMode.episode;
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
    final int offset = int.tryParse(_offsetController.text) ??
        (_mode == TrackingProgressMode.chapter ? 0 : 1);
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
                  if (!(_target?.isBook ?? false))
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
                  if (!(_target?.isBook ?? false))
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
                        value == TrackingProgressMode.chapter ? '0' : '1';
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _offsetController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.media_tracking_progress_offset,
                ),
              ),
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

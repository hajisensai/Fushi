import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/media_cover_source.dart';
import 'package:hibiki/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:hibiki/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:hibiki/src/media/video/stream_video_launch.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Stable reference to a canonical video work. A work is owned by either a
/// collection (episodic TV) or one VideoBook (standalone movie).
class VideoWorkRef {
  const VideoWorkRef.collection(this.collectionId) : bookUid = null;
  const VideoWorkRef.book(this.bookUid) : collectionId = null;

  final int? collectionId;
  final String? bookUid;
}

/// Unified work-level route. Collection works retain the mature episode and
/// management surface; standalone works use the same canonical v69/v70 data.
class VideoWorkDetailPage extends StatelessWidget {
  const VideoWorkDetailPage({
    required this.database,
    required this.repository,
    required this.workRef,
    required this.onChanged,
    this.onDeleteMembersMedia,
    super.key,
  });

  final HibikiDatabase database;
  final VideoBookRepository repository;
  final VideoWorkRef workRef;
  final VoidCallback onChanged;
  final Future<void> Function(List<VideoBookRow> members)? onDeleteMembersMedia;

  @override
  Widget build(BuildContext context) {
    final int? collectionId = workRef.collectionId;
    if (collectionId != null) {
      return FutureBuilder<MediaCollectionRow?>(
        future: database.getMediaCollectionById(collectionId),
        builder: (BuildContext context,
            AsyncSnapshot<MediaCollectionRow?> snapshot) {
          final MediaCollectionRow? collection = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return Scaffold(
              body: Center(child: adaptiveIndicator(context: context)),
            );
          }
          if (collection == null) {
            return Scaffold(
              appBar: AppBar(),
              body: Center(
                child: Text(t.video_load_failed_not_found),
              ),
            );
          }
          return MediaCollectionDetailPage(
            database: database,
            collection: collection,
            loadMembers: () async {
              final List<MediaCollectionItemRow> items =
                  await repository.getCollectionItems(collection.id);
              final List<VideoBookRow> result = <VideoBookRow>[];
              for (final MediaCollectionItemRow item in items) {
                if (item.mediaType != MediaKind.video.dbValue) continue;
                final VideoBookRow? row =
                    await repository.getByBookUid(item.entryKey);
                if (row != null) result.add(row);
              }
              return result;
            },
            onOpenEpisode: (VideoBookRow episode) {
              Navigator.push<void>(
                context,
                adaptivePageRoute<void>(
                  context: context,
                  builder: (_) => VideoHibikiPage.neutralized(
                    bookUid: episode.bookUid,
                    repo: repository,
                    playlistCollectionId: collection.id,
                  ),
                ),
              );
            },
            onChanged: onChanged,
            onDeleteMembersMedia: onDeleteMembersMedia,
          );
        },
      );
    }
    return _StandaloneVideoWorkDetail(
      database: database,
      repository: repository,
      bookUid: workRef.bookUid!,
      onChanged: onChanged,
    );
  }
}

class _StandaloneVideoWorkDetail extends StatefulWidget {
  const _StandaloneVideoWorkDetail({
    required this.database,
    required this.repository,
    required this.bookUid,
    required this.onChanged,
  });

  final HibikiDatabase database;
  final VideoBookRepository repository;
  final String bookUid;
  final VoidCallback onChanged;

  @override
  State<_StandaloneVideoWorkDetail> createState() =>
      _StandaloneVideoWorkDetailState();
}

class _StandaloneVideoWorkDetailState
    extends State<_StandaloneVideoWorkDetail> {
  VideoBookRow? _book;
  VideoMetadataWorkRow? _work;
  VideoMetadataWorkCredits? _credits;
  List<VideoMetadataTermRow> _terms = const <VideoMetadataTermRow>[];
  List<VideoMetadataExtraRow> _extras = const <VideoMetadataExtraRow>[];
  List<VideoMetadataImageRow> _images = const <VideoMetadataImageRow>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final VideoBookRow? book =
        await widget.repository.getByBookUid(widget.bookUid);
    final VideoMetadataWorkRow? work =
        await widget.database.getVideoMetadataWorkByBook(widget.bookUid);
    final VideoMetadataWorkCredits? credits =
        await VideoMetadataCreditRepository(widget.database)
            .forBook(widget.bookUid);
    final List<VideoMetadataTermRow> terms = work == null
        ? const <VideoMetadataTermRow>[]
        : await widget.database.getVideoMetadataTermsForWork(work.id);
    final List<VideoMetadataExtraRow> extras = work == null
        ? const <VideoMetadataExtraRow>[]
        : await widget.database.getVideoMetadataExtras(work.id);
    final List<VideoMetadataImageRow> images = work == null
        ? const <VideoMetadataImageRow>[]
        : await widget.database.getVideoMetadataImages(workId: work.id);
    if (!mounted) return;
    setState(() {
      _book = book;
      _work = work;
      _credits = credits;
      _terms = terms;
      _extras = extras;
      _images = images;
      _loading = false;
    });
  }

  ImageProvider? _image(String kind) {
    for (final VideoMetadataImageRow image in _images) {
      if (image.kind != kind) continue;
      final String? path = image.localPath;
      if (path != null && File(path).existsSync()) return FileImage(File(path));
      if (image.remoteUrl.isNotEmpty) return NetworkImage(image.remoteUrl);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(child: adaptiveIndicator(context: context)),
      );
    }
    final VideoBookRow? book = _book;
    if (book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(t.video_load_failed_not_found)),
      );
    }
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final VideoMetadataWorkRow? work = _work;
    final ImageProvider? poster = _image('poster') ??
        resolveMediaCoverImage(
            kind: MediaKind.video, localPath: book.coverPath);
    final ImageProvider? backdrop = _image('backdrop') ?? poster;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          SizedBox(
            height:
                (MediaQuery.sizeOf(context).height * 0.62).clamp(400.0, 620.0),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (backdrop != null)
                  LandscapeCoverImage(
                    image: backdrop,
                    overlays: const <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Color(0x22000000),
                              Color(0xE8000000),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    kToolbarHeight + tokens.spacing.page,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (poster != null)
                        SizedBox(
                          width: 210,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: ClipRRect(
                              borderRadius: HibikiBorderRadius.card,
                              child: PortraitCoverImage(image: poster),
                            ),
                          ),
                        ),
                      if (poster != null)
                        SizedBox(width: tokens.spacing.section),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              work?.title ?? book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            if (work?.originalTitle case final String title)
                              Text(
                                title,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            const SizedBox(height: 10),
                            Text(
                              <String>[
                                if (work?.year != null) '${work!.year}',
                                if (work?.status?.isNotEmpty == true)
                                  work!.status!,
                                if (work?.rating != null)
                                  '★ ${work!.rating!.toStringAsFixed(1)}',
                                if (work?.runtimeMinutes != null)
                                  '${work!.runtimeMinutes} min',
                              ].join(' · '),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: () => _playBook(book),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(book.lastPositionMs > 0
                                  ? t.video_continue_watching
                                  : t.collection_play),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (work?.overview?.trim().isNotEmpty == true)
            Padding(
              padding: EdgeInsets.all(tokens.spacing.page),
              child: SelectableText(
                work!.overview!,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.55,
                    ),
              ),
            ),
          _buildTerms(tokens),
          _buildCredits(tokens),
          _buildExtras(tokens),
          SizedBox(height: tokens.spacing.page),
        ],
      ),
    );
  }

  Widget _buildTerms(HibikiDesignTokens tokens) {
    if (_terms.isEmpty && (_credits?.identities.isEmpty ?? true)) {
      return const SizedBox.shrink();
    }
    final Map<String, List<String>> grouped = <String, List<String>>{};
    for (final VideoMetadataTermRow term in _terms) {
      grouped.putIfAbsent(term.kind, () => <String>[]).add(term.name);
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final MapEntry<String, List<String>> entry in grouped.entries)
            Chip(label: Text('${entry.key}: ${entry.value.join(' · ')}')),
          for (final VideoMetadataIdentitySummary id
              in _credits?.identities ?? const <VideoMetadataIdentitySummary>[])
            Chip(label: Text('${id.provider.toUpperCase()}: ${id.externalId}')),
        ],
      ),
    );
  }

  Widget _buildCredits(HibikiDesignTokens tokens) {
    final List<VideoMetadataCreditSummary> credits =
        _credits?.credits ?? const <VideoMetadataCreditSummary>[];
    if (credits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_work_cast_crew,
              style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: tokens.spacing.card),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final VideoMetadataCreditSummary credit in credits)
                Chip(
                  avatar: Icon(
                    credit.creditKind == 'voice_actor'
                        ? Icons.record_voice_over_outlined
                        : Icons.person_outline,
                    size: 18,
                  ),
                  label: Text(credit.displayName),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExtras(HibikiDesignTokens tokens) {
    if (_extras.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_work_trailers,
              style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: tokens.spacing.card),
          for (final VideoMetadataExtraRow extra in _extras)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_circle_outline),
              title: Text(extra.title),
              subtitle: Text(extra.kind),
              onTap: () => unawaited(_playExtra(extra)),
            ),
        ],
      ),
    );
  }

  void _playBook(VideoBookRow book) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoHibikiPage.neutralized(
          bookUid: book.bookUid,
          repo: widget.repository,
        ),
      ),
    );
  }

  Future<void> _playExtra(VideoMetadataExtraRow extra) async {
    if (extra.bookUid != null) {
      final VideoBookRow? local =
          await widget.repository.getByBookUid(extra.bookUid!);
      if (local != null && mounted) _playBook(local);
      return;
    }
    if (extra.remoteUrl == null) return;
    try {
      final launch = await buildOnlineVideoExtraLaunch(
        id: extra.extraKey,
        title: extra.title,
        url: extra.remoteUrl!,
      );
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => VideoHibikiPage.neutralizedRemote(
            info: launch.info,
            repo: widget.repository,
            client: launch.client,
          ),
        ),
      );
    } on Object {
      if (mounted) HibikiToast.show(msg: t.video_load_failed_generic);
    }
  }
}

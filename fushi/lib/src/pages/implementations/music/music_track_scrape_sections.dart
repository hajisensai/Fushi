/// 曲目详情的刮削区块（音乐方案 §8 / §11.2「曲目详情：原曲 / 其它版本 / MV」）：
///
/// - 识别：结论（途径 / 置信度）、重新识别、未认出时手选候选、「写回文件标签」（diff 预览）；
/// - 原曲与其它版本（§8.2）：同作品的录音，本地有的直接可播 / 进详情；
/// - MV（§8.3）：已绑定的 MV、本地声纹匹配、在线高置信候选（用户确认绑定）、动画 OP / ED。
///
/// 两套设计系统都走 Fushi 组件（按钮 / 列表 / 对话框自身按设计系统分派），进场与按压动效
/// 由宿主页的 `FushiEntranceScope` + 这里的 [FushiPressScale] / [FushiHoverLift] 提供。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/media/music/metadata/music_scrape_service.dart';
import 'package:fushi/src/media/music/metadata/music_tag_writeback.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// 途径的显示名。
String musicScrapeMethodLabel(String? method) => switch (method) {
  'mbid_tag' => t.music_scrape_method_mbid_tag,
  'tag_search' => t.music_scrape_method_tag_search,
  'acoustid' => t.music_scrape_method_acoustid,
  'manual' => t.music_scrape_method_manual,
  _ => method ?? '',
};

/// 标签字段的显示名。
String musicTagFieldLabel(MusicTagField f) => switch (f) {
  MusicTagField.title => t.music_tag_field_title,
  MusicTagField.artist => t.music_tag_field_artist,
  MusicTagField.album => t.music_tag_field_album,
  MusicTagField.albumArtist => t.music_tag_field_album_artist,
  MusicTagField.date => t.music_tag_field_date,
  MusicTagField.trackNo => t.music_tag_field_track_no,
  MusicTagField.discNo => t.music_tag_field_disc_no,
  MusicTagField.catalogNo => t.music_tag_field_catalog_no,
  MusicTagField.mbRecordingId => t.music_tag_field_mb_recording_id,
  MusicTagField.mbReleaseId => t.music_tag_field_mb_release_id,
  MusicTagField.mbReleaseGroupId => t.music_tag_field_mb_release_group_id,
  MusicTagField.mbWorkId => t.music_tag_field_mb_work_id,
  MusicTagField.mbArtistId => t.music_tag_field_mb_artist_id,
};

/// 识别结论的一行状态文案。
String musicScrapeStatusLabel(MusicScrapeMetaRow? meta) {
  if (meta == null) return t.music_scrape_status_none;
  return switch (meta.status) {
    MusicScrapeStatus.matched => t.music_scrape_status_matched(
      method: musicScrapeMethodLabel(meta.method),
    ),
    MusicScrapeStatus.unmatched => t.music_scrape_status_unmatched,
    _ => t.music_scrape_status_error,
  };
}

/// 存在 `versions_json` / `candidates_json` 里的一条录音。
class MusicStoredRecording {
  const MusicStoredRecording({
    required this.id,
    required this.title,
    this.artist,
    this.date,
    this.release,
    this.attributes = const <String>[],
  });

  final String id;
  final String title;
  final String? artist;
  final String? date;
  final String? release;
  final List<String> attributes;
}

/// 解码 `versions_json` / `candidates_json`（纯函数；坏 JSON 返回空表——它是本模块自己写的
/// 缓存列，坏了就当没有）。
List<MusicStoredRecording> decodeMusicStoredRecordings(String? raw) {
  if (raw == null || raw.isEmpty) return const <MusicStoredRecording>[];
  final Object? list;
  try {
    list = jsonDecode(raw);
  } on FormatException {
    return const <MusicStoredRecording>[];
  }
  if (list is! List<Object?>) return const <MusicStoredRecording>[];
  return <MusicStoredRecording>[
    for (final Object? e in list)
      if (e is Map<String, Object?> && e['id'] is String)
        MusicStoredRecording(
          id: e['id']! as String,
          title: e['title'] is String ? e['title']! as String : '',
          artist: e['artist'] as String?,
          date: e['date'] as String?,
          release: e['release'] as String?,
          attributes: <String>[
            if (e['attrs'] is List<Object?>)
              for (final Object? a in e['attrs']! as List<Object?>)
                if (a is String) a,
          ],
        ),
  ];
}

Future<void> _openMusicBrainz(String kind, String id) => launchUrl(
  Uri.parse('https://musicbrainz.org/$kind/$id'),
  mode: LaunchMode.externalApplication,
);

/// 识别区块。
class MusicTrackIdentificationSection extends StatefulWidget {
  const MusicTrackIdentificationSection({
    super.key,
    required this.database,
    required this.track,
    required this.service,
    this.onChanged,
  });

  final FushiDatabase database;
  final MusicTrackRow track;
  final MusicScrapeService service;

  /// 识别结论变了（宿主刷新原曲 / MV 区块）。
  final VoidCallback? onChanged;

  @override
  State<MusicTrackIdentificationSection> createState() =>
      _MusicTrackIdentificationSectionState();
}

class _MusicTrackIdentificationSectionState
    extends State<MusicTrackIdentificationSection> {
  late Future<MusicScrapeMetaRow?> _meta = _load();
  bool _busy = false;

  Future<MusicScrapeMetaRow?> _load() =>
      widget.database.getMusicScrapeMeta(widget.track.trackUid);

  void _reload() {
    setState(() => _meta = _load());
    widget.onChanged?.call();
  }

  Future<void> _identify({String? manual}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final MusicScrapeOutcome o = await widget.service.scrapeTrack(
        widget.track.trackUid,
        manualRecordingId: manual,
      );
      FushiToast.show(
        msg: switch (o.status) {
          MusicScrapeStatus.matched => t.music_scrape_done,
          MusicScrapeStatus.unmatched => t.music_scrape_not_matched,
          _ => t.music_scrape_failed,
        },
        severity: o.matched ? ToastSeverity.success : ToastSeverity.warning,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  Future<void> _chooseCandidate(MusicScrapeMetaRow meta) async {
    final List<MusicStoredRecording> cands = decodeMusicStoredRecordings(
      meta.candidatesJson,
    );
    if (cands.isEmpty) {
      FushiToast.show(msg: t.music_scrape_no_candidates);
      return;
    }
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.music_scrape_choose_match,
      icon: FushiIcons.search,
      options: <FushiChoiceOption<String>>[
        for (final MusicStoredRecording c in cands)
          FushiChoiceOption<String>(
            value: c.id,
            label: c.title,
            subtitle: <String>[
              if (c.artist?.isNotEmpty ?? false) c.artist!,
              if (c.release?.isNotEmpty ?? false) c.release!,
              if (c.date?.isNotEmpty ?? false) c.date!,
            ].join(' · '),
          ),
      ],
    );
    if (picked != null) await _identify(manual: picked);
  }

  Future<void> _writeBack() async {
    final MusicTagWriteback wb = MusicTagWriteback(database: widget.database);
    final MusicTagPreview preview = await wb.preview(widget.track.trackUid);
    if (!mounted) return;
    final String? blocked = switch (preview.blockedReason) {
      MusicTagBlocked.cueTrack => t.music_tag_writeback_cue,
      MusicTagBlocked.unreadable => t.music_tag_writeback_unreadable,
      MusicTagBlocked.notIdentified => t.music_scrape_status_none,
      _ => null,
    };
    if (blocked != null) {
      FushiToast.show(msg: blocked, severity: ToastSeverity.warning);
      return;
    }
    if (preview.changes.isEmpty) {
      FushiToast.show(msg: t.music_tag_writeback_no_changes);
      return;
    }
    final Set<MusicTagField>? selected =
        await showAppDialog<Set<MusicTagField>>(
          context: context,
          builder: (BuildContext _) =>
              MusicTagWritebackDialog(preview: preview),
        );
    if (selected == null) return;
    try {
      await wb.apply(preview, selected);
      FushiToast.show(
        msg: t.music_tag_writeback_done,
        severity: ToastSeverity.success,
      );
    } on MusicTagWriteException {
      FushiToast.show(
        msg: t.music_tag_writeback_failed,
        severity: ToastSeverity.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<MusicScrapeMetaRow?>(
      future: _meta,
      builder: (BuildContext context, AsyncSnapshot<MusicScrapeMetaRow?> s) {
        final MusicScrapeMetaRow? meta = s.data;
        final bool matched = meta?.status == MusicScrapeStatus.matched;
        final List<String> details = <String>[
          if (matched && meta?.title != null)
            <String>[
              meta!.title!,
              if (meta.artistCredit != null) meta.artistCredit!,
              if (meta.albumTitle != null) meta.albumTitle!,
            ].join(' · '),
          if (!widget.service.acoustidConfigured) t.music_scrape_acoustid_off,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSectionTitle(t.music_scrape_section),
            FushiGroupedListItem(
              index: 0,
              count: 1,
              child: FushiListItem(
                leading: FushiListLeadingIcon(
                  matched ? FushiIcons.check : FushiIcons.fingerprint,
                ),
                title: Text(musicScrapeStatusLabel(meta)),
                subtitle: details.isEmpty ? null : Text(details.join('\n')),
                subtitleMaxLines: 3,
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiPressScale(
                  child: FushiFilledButton.icon(
                    key: const ValueKey<String>('music_track_identify'),
                    onPressed: _busy ? null : () => unawaited(_identify()),
                    icon: const FushiIcon(FushiIcons.refresh),
                    label: Text(
                      _busy
                          ? t.music_scrape_identifying
                          : (meta == null
                                ? t.music_scrape_identify
                                : t.music_scrape_reidentify),
                    ),
                  ),
                ),
                if (meta != null && !matched && meta.candidatesJson != null)
                  FushiPressScale(
                    child: FushiOutlinedButton.icon(
                      key: const ValueKey<String>('music_track_choose_match'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_chooseCandidate(meta)),
                      icon: const FushiIcon(FushiIcons.search),
                      label: Text(t.music_scrape_choose_match),
                    ),
                  ),
                if (matched)
                  FushiPressScale(
                    child: FushiOutlinedButton.icon(
                      key: const ValueKey<String>('music_track_write_tags'),
                      onPressed: _busy ? null : () => unawaited(_writeBack()),
                      icon: const FushiIcon(FushiIcons.save),
                      label: Text(t.music_tag_writeback),
                    ),
                  ),
                if (matched && meta?.mbRecordingId != null)
                  FushiPressScale(
                    child: FushiOutlinedButton.icon(
                      onPressed: () => unawaited(
                        _openMusicBrainz('recording', meta!.mbRecordingId!),
                      ),
                      icon: const FushiIcon(FushiIcons.openInNew),
                      label: Text(t.music_scrape_open_musicbrainz),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 写回标签的 diff 预览：一行一个字段（旧值 → 新值），默认勾选没上锁的字段。
/// 关闭返回 null，确认返回勾选的字段集合。
class MusicTagWritebackDialog extends StatefulWidget {
  const MusicTagWritebackDialog({super.key, required this.preview});

  final MusicTagPreview preview;

  @override
  State<MusicTagWritebackDialog> createState() =>
      _MusicTagWritebackDialogState();
}

class _MusicTagWritebackDialogState extends State<MusicTagWritebackDialog> {
  late final Set<MusicTagField> _selected = <MusicTagField>{
    for (final MusicTagChange c in widget.preview.changes)
      if (!c.locked) c.field,
  };

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Text(t.music_tag_writeback),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.music_tag_writeback_hint, style: context.fushiType.bodySmall),
          for (final MusicTagChange c in widget.preview.changes)
            FushiCheckboxListTile(
              key: ValueKey<String>('music-tag-change-${c.field.wire}'),
              value: _selected.contains(c.field),
              onChanged: (bool? v) => setState(() {
                if (v ?? false) {
                  _selected.add(c.field);
                } else {
                  _selected.remove(c.field);
                }
              }),
              title: Text(musicTagFieldLabel(c.field)),
              subtitle: Text(
                '${c.current ?? t.music_tag_value_empty}  →  ${c.proposed}',
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('music_tag_writeback_apply'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(<MusicTagField>{..._selected}),
          child: Text(t.music_tag_writeback_apply),
        ),
      ],
    );
  }
}

/// 原曲与其它版本（§8.2）。
class MusicTrackVersionsSection extends StatelessWidget {
  const MusicTrackVersionsSection({
    super.key,
    required this.meta,
    required this.localByRecording,
    required this.onOpenLocal,
  });

  final MusicScrapeMetaRow meta;

  /// 录音 MBID → 本地曲目（「库中有」，点了进详情）。
  final Map<String, MusicTrackRow> localByRecording;
  final ValueChanged<MusicTrackRow> onOpenLocal;

  @override
  Widget build(BuildContext context) {
    final List<MusicStoredRecording> others = decodeMusicStoredRecordings(
      meta.versionsJson,
    );
    final String? originalId = meta.originalRecordingId;
    final List<({MusicStoredRecording rec, bool original})> rows =
        <({MusicStoredRecording rec, bool original})>[
          if (originalId != null && !meta.selfIsOriginal)
            (
              rec: MusicStoredRecording(
                id: originalId,
                title: meta.originalTitle ?? '',
                artist: meta.originalArtistCredit,
                date: meta.originalReleaseDate,
              ),
              original: true,
            ),
          for (final MusicStoredRecording r in others)
            (rec: r, original: false),
        ];
    if (rows.isEmpty && !meta.selfIsOriginal) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiSectionTitle(t.music_versions_section),
        if (meta.selfIsOriginal)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t.music_versions_this_is_original,
              style: context.fushiType.bodyMedium,
            ),
          ),
        for (int i = 0; i < rows.length; i++)
          _VersionTile(
            key: ValueKey<String>('music-version-${rows[i].rec.id}'),
            rec: rows[i].rec,
            original: rows[i].original,
            local: localByRecording[rows[i].rec.id],
            index: i,
            count: rows.length,
            onOpenLocal: onOpenLocal,
          ),
      ],
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({
    super.key,
    required this.rec,
    required this.original,
    required this.local,
    required this.index,
    required this.count,
    required this.onOpenLocal,
  });

  final MusicStoredRecording rec;
  final bool original;
  final MusicTrackRow? local;
  final int index;
  final int count;
  final ValueChanged<MusicTrackRow> onOpenLocal;

  @override
  Widget build(BuildContext context) {
    final List<String> tags = <String>[
      if (original) t.music_versions_original,
      if (rec.attributes.contains('cover')) t.music_versions_cover,
      if (rec.attributes.contains('live')) t.music_versions_live,
      if (local != null) t.music_versions_in_library,
    ];
    final MusicTrackRow? l = local;
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: l != null
            ? () => onOpenLocal(l)
            : () => unawaited(_openMusicBrainz('recording', rec.id)),
        child: FushiListItem(
          leading: FushiListLeadingIcon(
            l != null ? FushiIcons.play : FushiIcons.openInNew,
          ),
          title: Text(rec.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            <String>[
              if (rec.artist?.isNotEmpty ?? false) rec.artist!,
              if (rec.date?.isNotEmpty ?? false) rec.date!,
              ...tags,
            ].join(' · '),
          ),
        ),
      ),
    );
  }
}

/// MV 区块（§8.3）。
class MusicTrackVideosSection extends StatefulWidget {
  const MusicTrackVideosSection({
    super.key,
    required this.database,
    required this.track,
  });

  final FushiDatabase database;
  final MusicTrackRow track;

  @override
  State<MusicTrackVideosSection> createState() =>
      _MusicTrackVideosSectionState();
}

class _MusicTrackVideosSectionState extends State<MusicTrackVideosSection> {
  late final MusicVideoService _service = MusicVideoService(
    database: widget.database,
  );
  late Future<List<MusicVideoRow>> _rows = _load();
  bool _busy = false;

  Future<List<MusicVideoRow>> _load() =>
      widget.database.listMusicVideos(widget.track.trackUid);

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _rows = _load();
        });
      }
    }
  }

  Future<void> _findLocal() => _run(() async {
    final List<MusicLocalVideoMatch> found = await _service.matchLocal(
      widget.track.trackUid,
    );
    if (!found.any((MusicLocalVideoMatch m) => m.alignment != null)) {
      FushiToast.show(msg: t.music_mv_none_found);
    }
  });

  Future<void> _pick(Future<List<MusicVideoCandidate>> Function() load) =>
      _run(() async {
        final List<MusicVideoCandidate> list = await load();
        if (!mounted) return;
        if (list.isEmpty) {
          FushiToast.show(msg: t.music_mv_none_found);
          return;
        }
        final MusicVideoCandidate? c =
            await showFushiChoiceDialog<MusicVideoCandidate>(
              context: context,
              title: t.music_mv_candidates_title,
              icon: FushiIcons.video,
              options: <FushiChoiceOption<MusicVideoCandidate>>[
                for (final MusicVideoCandidate c in list)
                  FushiChoiceOption<MusicVideoCandidate>(
                    value: c,
                    label: c.title,
                    subtitle: c.subtitle,
                  ),
              ],
            );
        if (c != null) await _service.bind(widget.track.trackUid, c);
      });

  Future<void> _unbind(MusicVideoRow row) =>
      _run(() => widget.database.deleteMusicVideo(row.id));

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<List<MusicVideoRow>>(
      future: _rows,
      builder: (BuildContext context, AsyncSnapshot<List<MusicVideoRow>> s) {
        final List<MusicVideoRow> rows = s.data ?? const <MusicVideoRow>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSectionTitle(t.music_mv_section),
            for (int i = 0; i < rows.length; i++)
              FushiPressScale(
                key: ValueKey<String>('music-mv-${rows[i].id}'),
                child: FushiGroupedListItem(
                  index: i,
                  count: rows.length,
                  onTap: musicVideoPlayable(rows[i])
                      ? () => unawaited(
                          openMusicMvPage(
                            context: context,
                            track: widget.track,
                            binding: rows[i],
                          ),
                        )
                      : null,
                  child: FushiListItem(
                    leading: const FushiListLeadingIcon(FushiIcons.video),
                    title: Text(
                      musicVideoRefLabel(rows[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      t.music_mv_offset_value(ms: rows[i].offsetMs),
                    ),
                    trailing: FushiIconButton(
                      tooltip: t.music_mv_unbind,
                      icon: FushiIcons.close,
                      enabled: !_busy,
                      onTap: () => unawaited(_unbind(rows[i])),
                    ),
                  ),
                ),
              ),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('music_mv_find_local'),
                    onPressed: _busy ? null : () => unawaited(_findLocal()),
                    icon: const FushiIcon(FushiIcons.folder),
                    label: Text(
                      _busy ? t.music_mv_searching : t.music_mv_find_local,
                    ),
                  ),
                ),
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('music_mv_search_online'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _pick(
                              () => _service.onlineCandidates(
                                widget.track.trackUid,
                              ),
                            ),
                          ),
                    icon: const FushiIcon(FushiIcons.search),
                    label: Text(t.music_mv_search_online),
                  ),
                ),
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('music_mv_from_anime'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _pick(
                              () => _service.animeCandidates(
                                widget.track.trackUid,
                              ),
                            ),
                          ),
                    icon: const FushiIcon(FushiIcons.tv),
                    label: Text(t.music_mv_from_anime),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// [MusicVideoKind] 是否本模块能播（disc_chapter 留给 P5 光盘）。
bool musicVideoPlayable(MusicVideoRow row) =>
    row.kind == MusicVideoKind.local ||
    row.kind == MusicVideoKind.youtube ||
    row.kind == MusicVideoKind.animeEpisode;

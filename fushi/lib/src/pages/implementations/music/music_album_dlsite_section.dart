/// 专辑页的 DLsite 资料区块（拍板台 NCzkl6oLnf）：音声 / ASMR 专辑按文件夹 / 专辑名 /
/// 目录编号里的作品编号（`RJ…`）显示社团、声优、创作者、DLsite 标签、评分、销量、
/// 年龄分级，带「获取 / 刷新 DLsite 资料」与「在 DLsite 打开」。认不出编号的专辑整块
/// 不出现（普通音乐专辑不受影响）。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/item_scrape_detail_view.dart'
    show openItemScrapeLink;
import 'package:fushi/src/media/detail/media_detail_kit.dart'
    show MediaDetailChip, MediaDetailChipRow;
import 'package:fushi/src/media/music/metadata/music_dlsite_scraper.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/music/metadata/music_dlsite_album.dart';
import 'package:material_ui/material_ui.dart';

/// 专辑认得出 DLsite 作品编号（专辑页据此决定挂不挂 [MusicAlbumDlsiteSection]，
/// 普通音乐专辑不多占一格列表间距）。
bool musicAlbumHasDlsiteWork(MusicAlbumRow album, List<MusicTrackRow> tracks) =>
    _workIdOf(album, tracks) != null;

DlsiteWorkId? _workIdOf(MusicAlbumRow album, List<MusicTrackRow> tracks) =>
    musicAlbumDlsiteWorkId(
      title: album.title,
      catalogNo: album.catalogNo,
      trackPaths: <String>[for (final MusicTrackRow t in tracks) t.path],
    );

/// 专辑页 DLsite 区块。[album] / [tracks] 换了（重扫）会重新认编号、重读缓存。
class MusicAlbumDlsiteSection extends StatefulWidget {
  const MusicAlbumDlsiteSection({
    super.key,
    required this.album,
    required this.tracks,
    required this.scraper,
    this.launch,
  });

  final MusicAlbumRow album;
  final List<MusicTrackRow> tracks;
  final MusicDlsiteScraper scraper;

  /// 外链打开的测试接缝（null = 系统浏览器）。
  final Future<void> Function(Uri uri)? launch;

  @override
  State<MusicAlbumDlsiteSection> createState() =>
      _MusicAlbumDlsiteSectionState();
}

class _MusicAlbumDlsiteSectionState extends State<MusicAlbumDlsiteSection> {
  DlsiteWorkId? _id;
  MusicDlsiteAlbumInfo? _info;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MusicAlbumDlsiteSection old) {
    super.didUpdateWidget(old);
    if (!identical(old.album, widget.album) ||
        !identical(old.tracks, widget.tracks)) {
      _resolve();
    }
  }

  void _resolve() {
    final DlsiteWorkId? id = _workIdOf(widget.album, widget.tracks);
    if (id == _id && _info != null) return;
    _id = id;
    _info = null;
    if (id == null) return;
    unawaited(_loadCached(id));
  }

  Future<void> _loadCached(DlsiteWorkId id) async {
    final MusicDlsiteAlbumInfo? info = await widget.scraper.cachedInfo(id);
    if (!mounted || _id != id) return;
    setState(() => _info = info);
  }

  Future<void> _fetch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final MusicDlsiteAlbumInfo? info = await widget.scraper.scrapeAlbum(
        widget.album.albumUid,
      );
      if (!mounted) return;
      setState(() => _info = info);
      if (info != null && info.snapshot?.work == null) {
        FushiToast.show(
          msg: t.music_dlsite_not_found(id: info.id.value),
          severity: ToastSeverity.warning,
        );
      }
    } on DlsiteException catch (e) {
      FushiToast.show(
        msg: t.music_dlsite_fetch_failed(error: e.message),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DlsiteWorkId? id = _id;
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: context.fushiMotion.effectsDefault.curve,
      alignment: Alignment.topCenter,
      child: id == null
          ? const SizedBox(width: double.infinity)
          : _body(context, id),
    );
  }

  Widget _body(BuildContext context, DlsiteWorkId id) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicDlsiteSnapshot? snap = _info?.snapshot;
    final DlsiteWork? work = snap?.work;
    final List<(String, String)> facts = musicDlsiteFacts(id, work);
    final List<Widget> actions = <Widget>[
      FushiPressScale(
        child: FushiFilledButton.tonalIcon(
          size: FushiButtonSize.m,
          key: const ValueKey<String>('music_album_dlsite_fetch'),
          onPressed: _busy ? null : () => unawaited(_fetch()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(
            snap == null ? t.music_dlsite_fetch : t.music_dlsite_refresh,
          ),
        ),
      ),
      FushiPressScale(
        child: FushiOutlinedButton.icon(
          key: const ValueKey<String>('music_album_dlsite_open'),
          onPressed: () => unawaited(
            openItemScrapeLink(Uri.parse(id.pageUrl), launch: widget.launch),
          ),
          icon: const FushiIcon(FushiIcons.openInNew),
          label: Text(t.music_dlsite_open),
        ),
      ),
    ];
    return Column(
      key: const ValueKey<String>('music_album_dlsite_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle(t.music_dlsite_section_title),
        if (snap == null)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Text(t.music_dlsite_detected(id: id.value)),
          )
        else if (work == null)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Text(t.music_dlsite_not_found(id: id.value)),
          ),
        if (work != null) ...<Widget>[
          for (int i = 0; i < facts.length; i++)
            FushiGroupedListItem(
              index: i,
              count: facts.length,
              child: FushiListItem(
                density: FushiListDensity.compact,
                title: Text(facts[i].$1),
                subtitle: SelectableText(facts[i].$2),
                subtitleMaxLines: 4,
              ),
            ),
          if (work.genres.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(t.music_dlsite_tags, style: tokens.type.sectionLabel),
            SizedBox(height: tokens.spacing.gap * 0.5),
            MediaDetailChipRow(
              key: const ValueKey<String>('music_album_dlsite_tags'),
              chips: <MediaDetailChip>[
                for (final String g in work.genres) MediaDetailChip(g),
              ],
            ),
          ],
          SizedBox(height: tokens.spacing.gap),
        ],
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ],
    );
  }
}

/// 年龄分级显示名。
String musicDlsiteAgeLabel(DlsiteAgeCategory age) => switch (age) {
  DlsiteAgeCategory.general => t.music_dlsite_age_general,
  DlsiteAgeCategory.r15 => t.music_dlsite_age_r15,
  DlsiteAgeCategory.adult => t.music_dlsite_age_adult,
};

/// 资料行（标签 → 值）：作品编号、社团、声优、作者 / 剧本 / 插画 / 音乐、作品类型、
/// 发售日、评分（DLsite 五星均分 · 人数）、销量、收藏数、年龄分级。空字段不占行。纯函数，测试钉死。
List<(String, String)> musicDlsiteFacts(DlsiteWorkId id, DlsiteWork? work) {
  String join(List<String> names) => names.join(' / ');
  final List<(String, String)> out = <(String, String)>[
    (t.music_dlsite_field_work_id, id.value),
  ];
  if (work == null) return out;
  final String? circle = work.circle;
  if (circle != null && circle.isNotEmpty) {
    out.add((t.music_dlsite_field_circle, circle));
  }
  if (work.voiceActors.isNotEmpty) {
    out.add((t.music_dlsite_field_voice_actors, join(work.voiceActors)));
  }
  if (work.authors.isNotEmpty) {
    out.add((t.music_dlsite_field_author, join(work.authors)));
  }
  if (work.scenarioWriters.isNotEmpty) {
    out.add((t.music_dlsite_field_scenario, join(work.scenarioWriters)));
  }
  if (work.illustrators.isNotEmpty) {
    out.add((t.music_dlsite_field_illustration, join(work.illustrators)));
  }
  if (work.musicians.isNotEmpty) {
    out.add((t.music_dlsite_field_music, join(work.musicians)));
  }
  final String? type = work.workTypeLabel ?? work.workType;
  if (type != null && type.isNotEmpty) {
    out.add((t.music_dlsite_field_work_type, type));
  }
  final DateTime? date = work.releaseDate;
  if (date != null) {
    out.add((
      t.music_dlsite_field_release,
      date.toIso8601String().substring(0, 10),
    ));
  }
  final DlsiteRating? rating = work.rating;
  final double? avg = rating?.average;
  if (avg != null && avg > 0) {
    final int? count = rating?.count;
    out.add((
      t.music_dlsite_field_rating,
      count != null && count > 0
          ? t.music_dlsite_rating_value(
              rating: '★ ${avg.toStringAsFixed(2)}',
              count: count,
            )
          : '★ ${avg.toStringAsFixed(2)}',
    ));
  }
  final int? downloads = rating?.downloads;
  if (downloads != null && downloads > 0) {
    out.add((t.music_dlsite_field_downloads, '$downloads'));
  }
  final int? wishlists = rating?.wishlists;
  if (wishlists != null && wishlists > 0) {
    out.add((t.music_dlsite_field_wishlists, '$wishlists'));
  }
  final DlsiteAgeCategory? age = work.ageCategory;
  if (age != null) {
    out.add((t.music_dlsite_field_age, musicDlsiteAgeLabel(age)));
  }
  return out;
}

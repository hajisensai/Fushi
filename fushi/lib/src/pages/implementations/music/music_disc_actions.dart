/// 曲库里光盘专辑的操作（音乐方案 §9.2）：添加光盘、章节导入为曲目、按盘名查 MusicBrainz
/// 曲目表、从曲库移除。入口只在专辑详情与专辑卡右键 / 长按菜单——原盘菜单画面与 BD 一致，
/// 只有顶栏，不放这些。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_image_probe.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/music/disc/music_audio_cd.dart';
import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/video/cover_ui/disc_format_badge.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 光盘专辑的一条成员路径（给 `DiscFormatBadge` 判 DVD / BD / UHD 用；不是真实文件）。
String? musicDiscBadgeMemberPath(MusicDiscSourceRow disc) =>
    switch (MusicDiscKind.fromWire(disc.kind)) {
      MusicDiscKind.dvd => dvdTitlePath(disc.path, 1),
      MusicDiscKind.bluray => p.join(
        disc.path,
        'BDMV',
        'PLAYLIST',
        '00000.mpls',
      ),
      _ => null,
    };

/// 光盘专辑封面角标：DVD / BD / UHD 走视频库同一个 [DiscFormatBadge]（BD 要读 `index.bdmv`
/// 才分得出 UHD），音频 CD 直接是 `CD`。
class MusicDiscBadge extends ConsumerWidget {
  const MusicDiscBadge({super.key, required this.disc});

  final MusicDiscSourceRow disc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MusicDiscKind.fromWire(disc.kind) == MusicDiscKind.cdda) {
      return Semantics(
        label: 'CD',
        child: const ExcludeSemantics(child: CoverBadge(label: 'CD')),
      );
    }
    final String? member = musicDiscBadgeMemberPath(disc);
    if (member == null) return const SizedBox.shrink();
    return DiscFormatBadge(
      resolver: ref.read(discFormatResolverProvider),
      memberPaths: <String>[member],
    );
  }
}

/// 章节曲目的默认名（MusicBrainz 对号后会被改掉）。
String musicDiscChapterDefaultTitle(
  MusicDiscTitle title,
  MusicDiscChapter chapter, {
  required bool multipleTitles,
}) => multipleTitles
    ? t.music_disc_title_chapter_name(title: title.label, n: chapter.number)
    : t.music_disc_chapter_name(n: chapter.number);

/// 工具栏「添加光盘」：选一个目录——它本身是盘（DVD / BD 目录、光驱根）就登记它，否则登记
/// 目录树里认得出的全部盘（含 `.iso`）。返回登记了几张。
Future<int> pickAndAddMusicDiscs({
  required BuildContext context,
  required AppModel app,
}) async {
  final String? path = await pickRealDirectoryPath(
    context: context,
    appModel: app,
    dialogTitle: t.music_disc_add,
  );
  if (path == null || !context.mounted) return 0;
  final MusicDiscImportService service = MusicDiscImportService(app.database);
  final List<String> discs = await probeMusicDiscRoot(path) != null
      ? <String>[path]
      : await findMusicDiscRootsInBackground(path);
  int added = 0;
  String? firstError;
  for (final String disc in discs) {
    try {
      await service.registerDisc(disc);
      added++;
    } on MusicDiscUnreadableException {
      firstError ??= await _unreadableMessage(disc);
    } on Exception catch (e) {
      firstError ??= e.toString();
    }
  }
  if (added == 0) {
    FushiToast.show(
      msg: firstError ?? t.music_disc_none_found,
      severity: ToastSeverity.warning,
    );
  } else {
    FushiToast.show(msg: t.music_disc_added(count: added));
  }
  return added;
}

/// 读不出来的盘给出具体原因：BD 镜像暂不支持章节导入（MPLS 在镜像里，播放端要真实 m2ts
/// 路径拼 EDL），其余是「不是可读的 DVD / 蓝光」。
Future<String> _unreadableMessage(String path) async {
  if (FileSystemEntity.isFileSync(path) && isDiscImagePath(path)) {
    final DiscImageProbe? probe = await probeDiscImageFile(path);
    if (probe != null && probe.format != DiscFormat.dvd) {
      return t.music_disc_bluray_image_unsupported;
    }
  }
  return t.music_disc_unreadable(path: path);
}

String _titleOptionLabel(MusicDiscTitle title) => t.music_disc_title_option(
  title: title.label,
  duration: formatMusicDuration(title.duration.inMilliseconds),
  count: title.chapters.isEmpty ? 1 : title.chapters.length,
);

/// 「章节导入为曲目」：读盘 → 选 title（默认正片）→ 落库。返回导入的曲目数（取消 / 失败为
/// null）。
Future<int?> importMusicDiscChapters({
  required BuildContext context,
  required AppModel app,
  required MusicDiscSourceRow disc,
}) async {
  final MusicDiscImportService service = MusicDiscImportService(app.database);
  final MusicDiscInfo info;
  try {
    info = await service.readDisc(disc.path);
  } on MusicDiscUnreadableException {
    FushiToast.show(
      msg: await _unreadableMessage(disc.path),
      severity: ToastSeverity.warning,
    );
    return null;
  } on Exception catch (e) {
    FushiToast.show(
      msg: t.music_disc_unreadable(path: '${disc.path} ($e)'),
      severity: ToastSeverity.error,
    );
    return null;
  }
  if (!context.mounted) return null;
  // 上一轮导入了哪些 title：重新导入时默认勾回去；第一次导入默认勾正片。
  final Set<int> previous = <int>{
    for (final MusicDiscTrackRef r in decodeMusicDiscTitleMap(
      disc.titleMapJson,
    ))
      r.titleNumber,
  };
  final Set<int> initial = previous.isNotEmpty
      ? previous
      : <int>{
          for (final MusicDiscTitle title in info.titles)
            if (title.isMainFeature) title.number,
        };
  final Set<int>? chosen = await showFushiMultiChoiceDialog<int>(
    context: context,
    title: t.music_disc_choose_titles,
    message: t.music_disc_choose_titles_hint,
    confirmLabel: t.music_disc_import_chapters,
    minSelected: 1,
    initial: initial,
    options: <FushiChoiceOption<int>>[
      for (final MusicDiscTitle title in info.titles)
        FushiChoiceOption<int>(
          value: title.number,
          label: _titleOptionLabel(title),
          subtitle: title.isMainFeature ? t.music_disc_title_main : null,
          icon: FushiIcons.toc,
        ),
    ],
  );
  if (chosen == null || chosen.isEmpty) return null;
  final bool multiple = chosen.length > 1;
  try {
    final int count = await service.importChapters(
      info,
      titleNumbers: chosen,
      chapterTitle: (MusicDiscTitle title, MusicDiscChapter c) =>
          musicDiscChapterDefaultTitle(title, c, multipleTitles: multiple),
    );
    FushiToast.show(msg: t.music_disc_imported(count: count));
    return count;
  } on MusicDiscNoChaptersException {
    FushiToast.show(
      msg: t.music_disc_no_chapters,
      severity: ToastSeverity.warning,
    );
    return null;
  }
}

/// 「在 MusicBrainz 查曲目表」：按盘名（可改）搜 DVD / BD 发行，曲数 + 时长对号，用户选一张
/// 套用到曲目名。返回是否套用了。
Future<bool> lookupMusicDiscRelease({
  required BuildContext context,
  required AppModel app,
  required MusicAlbumRow album,
  required List<MusicTrackRow> tracks,
  MusicReleaseProvider? provider,
}) async {
  if (tracks.isEmpty) return false;
  final String? query = await showFushiTextInputDialog(
    context: context,
    title: t.music_disc_lookup,
    message: t.music_disc_lookup_hint,
    labelText: t.music_disc_lookup_query,
    initialValue: album.title,
    icon: FushiIcons.search,
  );
  if (query == null || query.isEmpty || !context.mounted) return false;
  final List<int> chapterMs = <int>[
    for (final MusicTrackRow track in tracks) track.durationMs ?? 0,
  ];
  final FushiProgressDialogHandle progress = showFushiProgressDialog(
    context: context,
    title: t.music_disc_lookup_searching,
  );
  final MusicReleaseProvider mb = provider ?? MusicBrainzProvider();
  List<MusicDiscReleaseMatch> matches;
  try {
    matches = rankMusicDiscReleaseMatches(
      chapterMs,
      await mb.searchDiscReleases(query, artist: album.albumArtistCredit),
    );
  } on Exception catch (e) {
    progress.close();
    FushiToast.show(
      msg: t.music_disc_lookup_failed(error: e.toString()),
      severity: ToastSeverity.error,
    );
    return false;
  } finally {
    if (provider == null) mb.close();
  }
  progress.close();
  if (!context.mounted) return false;
  if (matches.isEmpty) {
    FushiToast.show(
      msg: t.music_disc_lookup_none,
      severity: ToastSeverity.warning,
    );
    return false;
  }
  final MusicDiscReleaseMatch? picked =
      await showFushiChoiceDialog<MusicDiscReleaseMatch>(
        context: context,
        title: t.music_disc_lookup_pick,
        icon: FushiIcons.music,
        options: <FushiChoiceOption<MusicDiscReleaseMatch>>[
          for (final MusicDiscReleaseMatch m in matches)
            FushiChoiceOption<MusicDiscReleaseMatch>(
              value: m,
              label: m.release.title,
              subtitle: <String>[
                ?m.release.artistCredit,
                ?m.release.date,
                if (m.release.formatSummary.isNotEmpty) m.release.formatSummary,
                t.music_tracks_count(count: m.tracks.length),
                if (m.meanErrorMs case final int e)
                  t.music_disc_match_error(
                    seconds: (e / 1000).toStringAsFixed(1),
                  ),
              ].join(' · '),
              icon: m.isConfident ? FushiIcons.check : FushiIcons.music,
            ),
        ],
      );
  if (picked == null) return false;
  final bool applied = await MusicDiscImportService(
    app.database,
  ).applyRelease(albumUid: album.albumUid, match: picked, tracks: tracks);
  FushiToast.show(
    msg: applied ? t.music_disc_lookup_applied : t.music_disc_lookup_none,
    severity: applied ? ToastSeverity.success : ToastSeverity.warning,
  );
  return applied;
}

/// 从曲库移除一张盘（确认后）：盘上的文件不动。
Future<bool> removeMusicDiscFromLibrary({
  required BuildContext context,
  required AppModel app,
  required MusicDiscSourceRow disc,
}) async {
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.music_disc_remove,
    message: t.music_disc_remove_confirm,
    destructive: true,
  );
  if (!ok) return false;
  await app.database.removeMusicDisc(
    discUid: disc.discUid,
    deletedAt: DateTime.now().millisecondsSinceEpoch,
  );
  return true;
}

/// 本机能不能读物理光驱（桌面三端）。
bool musicAudioCdSupported() =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 工具栏「读取音频 CD」/ CD 专辑的「重新读盘」：选光驱（只有一台就直接用）→ 读 TOC /
/// CD-TEXT → MusicBrainz Disc ID 查发行（多张时让用户选）→ 入库。返回专辑 uid（取消 / 失败
/// 为 null）。
Future<String?> readAudioCdIntoLibrary({
  required BuildContext context,
  required AppModel app,
  String? device,
  MusicAudioCdService? service,
  MusicReleaseProvider? provider,
}) async {
  final MusicAudioCdService cd = service ?? MusicAudioCdService(app.database);
  String? drive = device;
  if (drive == null) {
    final List<String> drives = await cd.listDrives();
    if (!context.mounted) return null;
    if (drives.isEmpty) {
      FushiToast.show(
        msg: t.music_cd_no_drive,
        severity: ToastSeverity.warning,
      );
      return null;
    }
    drive = drives.length == 1
        ? drives.single
        : await showFushiChoiceDialog<String>(
            context: context,
            title: t.music_cd_choose_drive,
            icon: FushiIcons.audio,
            options: <FushiChoiceOption<String>>[
              for (final String d in drives)
                FushiChoiceOption<String>(
                  value: d,
                  label: d,
                  icon: FushiIcons.audio,
                ),
            ],
          );
    if (drive == null || !context.mounted) return null;
  }
  final FushiProgressDialogHandle progress = showFushiProgressDialog(
    context: context,
    title: t.music_cd_reading,
  );
  final AudioCdInfo info;
  List<MusicReleaseTracklist> releases = const <MusicReleaseTracklist>[];
  final MusicReleaseProvider mb = provider ?? MusicBrainzProvider();
  try {
    try {
      info = await cd.read(drive);
    } on AudioCdReadException {
      progress.close();
      FushiToast.show(
        msg: t.music_cd_read_failed(device: drive),
        severity: ToastSeverity.warning,
      );
      return null;
    } on MusicAudioCdNotAudioException {
      progress.close();
      FushiToast.show(
        msg: t.music_cd_not_audio(device: drive),
        severity: ToastSeverity.warning,
      );
      return null;
    }
    progress.message.value = t.music_disc_lookup_searching;
    try {
      releases = await cd.lookup(info, mb);
    } on Exception catch (e) {
      // 查不到网络照样入库（CD-TEXT / 轨号），只提示一句。
      FushiToast.show(
        msg: t.music_disc_lookup_failed(error: e.toString()),
        severity: ToastSeverity.warning,
      );
    }
  } finally {
    if (provider == null) mb.close();
    progress.close();
  }
  if (!context.mounted) return null;
  MusicReleaseTracklist? release;
  if (releases.length == 1) {
    release = releases.single;
  } else if (releases.length > 1) {
    release = await showFushiChoiceDialog<MusicReleaseTracklist>(
      context: context,
      title: t.music_disc_lookup_pick,
      icon: FushiIcons.music,
      options: <FushiChoiceOption<MusicReleaseTracklist>>[
        for (final MusicReleaseTracklist r in releases)
          FushiChoiceOption<MusicReleaseTracklist>(
            value: r,
            label: r.title,
            subtitle: <String>[
              ?r.artistCredit,
              ?r.date,
              ?r.country,
              if (r.catalogNumbers.isNotEmpty) r.catalogNumbers.first,
            ].join(' · '),
            icon: FushiIcons.music,
          ),
      ],
    );
    if (!context.mounted) return null;
  } else {
    FushiToast.show(msg: t.music_cd_lookup_none);
  }
  final String albumUid = await cd.import(
    info,
    device: drive,
    release: release,
    fallbackTitle: (int n) => t.music_cd_track_name(n: n),
    fallbackAlbumTitle: t.music_cd_album_name,
  );
  FushiToast.show(
    msg: t.music_cd_imported(
      title: release?.title ?? info.albumTitle ?? t.music_cd_album_name,
      count: info.audioTracks.length,
    ),
    severity: ToastSeverity.success,
  );
  return albumUid;
}

/// 光盘专辑的菜单项。
enum MusicDiscMenuAction { importChapters, lookup, remove }

/// 专辑卡右键 / 长按菜单（光盘专辑才有）。[globalPosition] 是按下处的全局坐标。
Future<void> showMusicDiscAlbumMenu({
  required BuildContext context,
  required AppModel app,
  required Offset globalPosition,
  required MusicAlbumRow album,
  required MusicDiscSourceRow disc,
  required List<MusicTrackRow> tracks,
}) async {
  final RenderObject? overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return;
  // 坐标经 Overlay globalToLocal 消掉界面缩放（BUG-781 同族纪律）。
  final Offset anchor = overlay.globalToLocal(globalPosition);
  PopupMenuItem<MusicDiscMenuAction> item(
    MusicDiscMenuAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<MusicDiscMenuAction>(
    value: value,
    child: Row(
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );
  final MusicDiscMenuAction? action = await showFushiMenu<MusicDiscMenuAction>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(anchor, anchor),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<MusicDiscMenuAction>>[
      item(
        MusicDiscMenuAction.importChapters,
        FushiIcons.toc,
        musicDiscImportLabel(disc, hasTracks: tracks.isNotEmpty),
      ),
      if (tracks.isNotEmpty &&
          MusicDiscKind.fromWire(disc.kind) != MusicDiscKind.cdda)
        item(
          MusicDiscMenuAction.lookup,
          FushiIcons.search,
          t.music_disc_lookup,
        ),
      item(MusicDiscMenuAction.remove, FushiIcons.delete, t.music_disc_remove),
    ],
  );
  if (action == null || !context.mounted) return;
  await runMusicDiscMenuAction(
    context: context,
    app: app,
    action: action,
    album: album,
    disc: disc,
    tracks: tracks,
  );
}

/// 「导入」类动作的文字：DVD / BD 是章节导入，音频 CD 是重新读盘（再查一次 Disc ID）。
String musicDiscImportLabel(
  MusicDiscSourceRow disc, {
  required bool hasTracks,
}) {
  if (MusicDiscKind.fromWire(disc.kind) == MusicDiscKind.cdda) {
    return t.music_cd_reread;
  }
  return hasTracks
      ? t.music_disc_reimport_chapters
      : t.music_disc_import_chapters;
}

Future<void> runMusicDiscMenuAction({
  required BuildContext context,
  required AppModel app,
  required MusicDiscMenuAction action,
  required MusicAlbumRow album,
  required MusicDiscSourceRow disc,
  required List<MusicTrackRow> tracks,
}) async {
  switch (action) {
    case MusicDiscMenuAction.importChapters:
      if (MusicDiscKind.fromWire(disc.kind) == MusicDiscKind.cdda) {
        await readAudioCdIntoLibrary(
          context: context,
          app: app,
          device: disc.path,
        );
      } else {
        await importMusicDiscChapters(context: context, app: app, disc: disc);
      }
    case MusicDiscMenuAction.lookup:
      await lookupMusicDiscRelease(
        context: context,
        app: app,
        album: album,
        tracks: tracks,
      );
    case MusicDiscMenuAction.remove:
      await removeMusicDiscFromLibrary(context: context, app: app, disc: disc);
  }
}

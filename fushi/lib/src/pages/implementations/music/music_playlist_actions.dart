/// 本地歌单与服务器（Jellyfin / Emby）歌单共用的编辑动作：加歌（[MusicPlaylistEditor] 的两个
/// 实现）、改名、删除、导入播放列表文件、导出 `.m3u8`。
///
/// 选歌单 / 新建歌单的流程与菜单外观仍在 music_track_actions.dart，这里只回答「本地 / 服务器
/// 各自怎么做」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_local_playlists.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 歌单动作失败的提示文案。
String musicPlaylistErrorText(Object e) =>
    t.music_action_playlist_failed(error: '$e');

int _now() => DateTime.now().millisecondsSinceEpoch;

// -------------------------------------------------------------------------
// 加歌：本地 / 服务器
// -------------------------------------------------------------------------

/// 本地歌单当作「可加歌的歌单来源」（曲目 id = 曲库 `trackUid`）。
class LocalMusicPlaylistEditor implements MusicPlaylistEditor {
  LocalMusicPlaylistEditor(this.db);

  final FushiDatabase db;

  @override
  Future<List<MusicPlaylistTarget>> editablePlaylists() async {
    final Map<String, int> counts = await db.musicPlaylistEntryCounts();
    return <MusicPlaylistTarget>[
      for (final MusicPlaylistRow p in await db.listMusicPlaylists())
        MusicPlaylistTarget(
          id: p.playlistUid,
          title: p.name,
          trackCount: counts[p.playlistUid] ?? 0,
        ),
    ];
  }

  @override
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async {
    final String uid = newMusicPlaylistUid();
    await db.createMusicPlaylist(
      playlistUid: uid,
      name: name,
      trackUids: trackIds,
      now: _now(),
    );
    return MusicPlaylistTarget(
      id: uid,
      title: name,
      trackCount: trackIds.length,
    );
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      db.appendMusicPlaylistTracks(playlistId, trackIds, now: _now());
}

/// 能改歌单的服务器（[MusicServerPlaylistEditing]）当作「可加歌的歌单来源」。
class MusicServerPlaylistEditor implements MusicPlaylistEditor {
  MusicServerPlaylistEditor(this.browser, this.editing);

  final MusicServerBrowser browser;
  final MusicServerPlaylistEditing editing;

  /// 浏览器能改歌单时回编辑器；Apple Music 等走自己的实现，这里回 null。
  static MusicServerPlaylistEditor? of(MusicServerBrowser browser) =>
      browser is MusicServerPlaylistEditing
      ? MusicServerPlaylistEditor(
          browser,
          browser as MusicServerPlaylistEditing,
        )
      : null;

  static MusicPlaylistTarget _target(MusicServerPlaylist p) =>
      MusicPlaylistTarget(id: p.id, title: p.title, trackCount: p.trackCount);

  @override
  Future<List<MusicPlaylistTarget>> editablePlaylists() async {
    final List<MusicPlaylistTarget> out = <MusicPlaylistTarget>[];
    int? offset = 0;
    // 一般就一两页；上限防服务器分页信息异常时无限翻。
    for (int page = 0; offset != null && page < 20; page++) {
      final MusicServerPage<MusicServerPlaylist> r = await browser
          .listPlaylists(offset: offset);
      out.addAll(<MusicPlaylistTarget>[
        for (final MusicServerPlaylist p in r.items)
          if (p.editable) _target(p),
      ]);
      offset = r.nextOffset;
    }
    return out;
  }

  @override
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async => _target(await editing.createPlaylist(name, trackIds: trackIds));

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      editing.addToPlaylist(playlistId, trackIds);
}

/// 把曲库曲目加进一个本地歌单（选歌单 / 新建）。失败提示，不抛。
Future<void> musicAddLocalTracksToPlaylist(
  BuildContext context,
  List<String> trackUids,
) async {
  if (trackUids.isEmpty) return;
  final FushiDatabase db = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider).database;
  try {
    await musicAddToPlaylist(context, LocalMusicPlaylistEditor(db), trackUids);
  } on Object catch (e) {
    FushiToast.show(
      msg: musicPlaylistErrorText(e),
      severity: ToastSeverity.error,
    );
  }
}

// -------------------------------------------------------------------------
// 改名 / 删除（本地与服务器共用的对话框）
// -------------------------------------------------------------------------

/// 问新名字并改名；成功提示。取消 / 没变回 null，否则回新名字。
Future<String?> musicRenamePlaylist(
  BuildContext context, {
  required String current,
  required Future<void> Function(String name) rename,
}) async {
  final String? name = await showFushiTextInputDialog(
    context: context,
    title: t.music_action_rename_playlist,
    labelText: t.music_action_playlist_name,
    initialValue: current,
    icon: FushiIcons.edit,
  );
  if (name == null || name.isEmpty || name == current) return null;
  try {
    await rename(name);
  } on Object catch (e) {
    FushiToast.show(
      msg: musicPlaylistErrorText(e),
      severity: ToastSeverity.error,
    );
    return null;
  }
  FushiToast.show(
    msg: t.music_action_playlist_renamed(name: name),
    severity: ToastSeverity.success,
  );
  return name;
}

/// 确认后删除；成功提示。回是否删了。
Future<bool> musicDeletePlaylist(
  BuildContext context, {
  required String name,
  required Future<void> Function() delete,
}) async {
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.music_action_delete_playlist,
    message: t.music_action_delete_playlist_confirm(name: name),
    icon: FushiIcons.delete,
    destructive: true,
  );
  if (!ok) return false;
  try {
    await delete();
  } on Object catch (e) {
    FushiToast.show(
      msg: musicPlaylistErrorText(e),
      severity: ToastSeverity.error,
    );
    return false;
  }
  FushiToast.show(
    msg: t.music_action_playlist_deleted(name: name),
    severity: ToastSeverity.success,
  );
  return true;
}

// -------------------------------------------------------------------------
// 导入（手动选文件）
// -------------------------------------------------------------------------

/// 选一个 `.m3u` / `.m3u8` 导入成本地歌单（条目对曲库，见 music_local_playlists.dart）。
/// 回新歌单的 uid；取消 / 没导入回 null（原因已提示）。
Future<String?> musicImportPlaylistFile(FushiDatabase db) async {
  // 不传 FileType.custom 扩展名过滤（部分平台的选择器把 .m3u 认成音频 MIME 后灰掉，
  // BUG-2099 同一纪律），选了别的文件在下面按扩展名拒。
  final FilePickerResult? picked = await FilePicker.platform.pickFiles(
    dialogTitle: t.music_action_import_playlist,
  );
  final String? path = picked?.files.single.path;
  if (path == null) return null;
  final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (!kMusicPlaylistFileExtensions.contains(ext)) {
    FushiToast.show(
      msg: t.music_action_playlist_import_no_matches,
      severity: ToastSeverity.warning,
    );
    return null;
  }
  try {
    final MusicPlaylistFile file = parseMusicPlaylistFile(
      await File(path).readAsBytes(),
      baseDir: p.dirname(path),
    );
    final ({
      MusicPlaylistImportOutcome outcome,
      String playlistUid,
      int matched,
    })
    r = await importMusicPlaylistFile(
      db,
      path: path,
      file: file,
      now: _now(),
      forceNewCopy: true,
    );
    final String name = musicPlaylistFileTitle(path, file);
    switch (r.outcome) {
      case MusicPlaylistImportOutcome.imported:
        FushiToast.show(
          msg: t.music_action_playlist_imported(name: name, count: r.matched),
          severity: ToastSeverity.success,
        );
        return r.playlistUid;
      case MusicPlaylistImportOutcome.alreadyImported:
        final MusicPlaylistRow? existing = await db.getMusicPlaylist(
          r.playlistUid,
        );
        FushiToast.show(
          msg: t.music_action_playlist_import_already(
            name: existing?.name ?? name,
          ),
        );
        return r.playlistUid;
      case MusicPlaylistImportOutcome.noMatches:
        FushiToast.show(
          msg: t.music_action_playlist_import_no_matches,
          severity: ToastSeverity.warning,
        );
        return null;
    }
  } on Object catch (e) {
    FushiToast.show(
      msg: musicPlaylistErrorText(e),
      severity: ToastSeverity.error,
    );
    return null;
  }
}

// -------------------------------------------------------------------------
// 导出 .m3u8
// -------------------------------------------------------------------------

/// 文件名里不能有的字符换成 `_`。
String musicPlaylistExportFileName(String name) {
  final String safe = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
  return '${safe.isEmpty ? 'playlist' : safe}.m3u8';
}

/// 导出到 `.m3u8`：桌面弹保存框（本地路径按输出目录写成相对路径），移动端走分享。
/// [skipped] 是没能导出的曲目数（服务器没报文件路径），非零时提示。
Future<void> musicExportPlaylistM3u8({
  required String name,
  required List<MusicPlaylistExportItem> items,
  int skipped = 0,
}) async {
  if (items.isEmpty) {
    FushiToast.show(
      msg: t.music_action_playlist_export_none,
      severity: ToastSeverity.warning,
    );
    return;
  }
  final String fileName = musicPlaylistExportFileName(name);
  try {
    if (isDesktopPlatform) {
      final String? out = await FilePicker.platform.saveFile(
        dialogTitle: t.music_action_export_playlist,
        fileName: fileName,
      );
      if (out == null || out.trim().isEmpty) return;
      await File(out).writeAsString(
        encodeMusicPlaylistM3u8(
          name: name,
          items: items,
          relativeTo: p.dirname(out),
        ),
        encoding: utf8,
        flush: true,
      );
      FushiToast.show(
        msg: t.music_action_playlist_exported(path: out),
        severity: ToastSeverity.success,
      );
    } else {
      final Directory dir = await Directory(
        p.join(Directory.systemTemp.path, 'fushi_playlist_export'),
      ).create(recursive: true);
      final String out = p.join(dir.path, fileName);
      await File(out).writeAsString(
        encodeMusicPlaylistM3u8(name: name, items: items),
        encoding: utf8,
        flush: true,
      );
      await FushiShare.shareFiles(<XFile>[
        XFile(out, mimeType: 'audio/x-mpegurl', name: fileName),
      ], subject: fileName);
    }
  } on Object catch (e) {
    FushiToast.show(
      msg: musicPlaylistErrorText(e),
      severity: ToastSeverity.error,
    );
    return;
  }
  if (skipped > 0) {
    FushiToast.show(
      msg: t.music_action_playlist_export_skipped(count: skipped),
      severity: ToastSeverity.warning,
    );
  }
}

/// 服务器歌单 → 导出条目：只收服务器报了文件路径的曲目；回（条目, 跳过数）。
({List<MusicPlaylistExportItem> items, int skipped}) musicServerExportItems(
  List<MusicServerTrack> tracks,
) {
  final List<MusicPlaylistExportItem> items = <MusicPlaylistExportItem>[];
  int skipped = 0;
  for (final MusicServerTrack tr in tracks) {
    final String? path = tr.path;
    if (path == null || path.isEmpty) {
      skipped++;
      continue;
    }
    items.add(
      MusicPlaylistExportItem(
        location: path,
        title: tr.title,
        artist: tr.artist,
        durationMs: tr.durationMs,
      ),
    );
  }
  return (items: items, skipped: skipped);
}

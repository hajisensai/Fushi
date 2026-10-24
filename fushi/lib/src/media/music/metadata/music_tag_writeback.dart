/// 「写回文件标签」（音乐方案 §8.1：识别结果写 DB，写回文件是显式操作，Picard 式 diff 预览）。
///
/// 流程：[MusicTagWriteback.preview] 读文件当前标签（后台 isolate，native/fushi_music）与
/// 识别结论比对，给出逐字段 diff；用户在预览里勾选后 [MusicTagWriteback.apply] 只写勾选的
/// 字段，**没勾的已变更字段记成字段锁**（下次预览不再提议，Picard「保留原值」语义）。
///
/// CUE 虚拟曲目不能写回：一份整轨文件只有一组标签，写进去会改到同盘所有曲目。
library;

import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 字段锁的实体种类（`music_locked_fields.entity_kind`）。
abstract final class MusicLockEntity {
  static const String track = 'track';
  static const String album = 'album';
}

/// 一个字段的 diff。
class MusicTagChange {
  const MusicTagChange({
    required this.field,
    required this.current,
    required this.proposed,
    required this.locked,
  });

  final MusicTagField field;

  /// 文件里现在的值（没有 = null）。
  final String? current;

  /// 识别结论给的值。
  final String proposed;

  /// 用户以前拒绝过（字段锁）：预览默认不勾。
  final bool locked;
}

/// 预览结果。
class MusicTagPreview {
  const MusicTagPreview({
    required this.trackUid,
    required this.path,
    required this.changes,
    this.blockedReason,
  });

  final String trackUid;
  final String path;

  /// 只含「识别值与文件值不同」的字段。
  final List<MusicTagChange> changes;

  /// 不能写回的原因（CUE 虚拟曲目 / 没有识别结论 / 文件读不了）。
  final String? blockedReason;

  bool get canWrite => blockedReason == null && changes.isNotEmpty;
}

/// 不能写回的原因码（界面翻译成文案）。
abstract final class MusicTagBlocked {
  static const String cueTrack = 'cue_track';
  static const String notIdentified = 'not_identified';
  static const String unreadable = 'unreadable';
}

/// 识别结论 → 提议写进文件的值（纯函数）。空值不提议（识别没给的字段不删文件里的值）。
Map<MusicTagField, String> proposedMusicTags(MusicScrapeMetaRow meta) {
  final Map<MusicTagField, String> out = <MusicTagField, String>{};
  void put(MusicTagField f, Object? v) {
    final String s = v?.toString().trim() ?? '';
    if (s.isNotEmpty) out[f] = s;
  }

  put(MusicTagField.title, meta.title);
  put(MusicTagField.artist, meta.artistCredit);
  put(MusicTagField.album, meta.albumTitle);
  put(MusicTagField.albumArtist, meta.albumArtistCredit);
  put(MusicTagField.date, meta.releaseDate);
  put(MusicTagField.trackNo, meta.trackNo);
  put(MusicTagField.discNo, meta.discNo);
  put(MusicTagField.catalogNo, meta.catalogNo);
  put(MusicTagField.mbRecordingId, meta.mbRecordingId);
  put(MusicTagField.mbReleaseId, meta.mbReleaseId);
  put(MusicTagField.mbReleaseGroupId, meta.mbReleaseGroupId);
  put(MusicTagField.mbWorkId, meta.mbWorkId);
  put(MusicTagField.mbArtistId, meta.mbArtistId);
  return out;
}

/// 提议值 vs 文件值 → diff（纯函数）。数字字段按数值比（`03` == `3`）。
List<MusicTagChange> diffMusicTags({
  required Map<MusicTagField, String> current,
  required Map<MusicTagField, String> proposed,
  required Set<String> lockedFields,
}) {
  bool same(MusicTagField f, String? a, String b) {
    if (a == null) return false;
    if (f == MusicTagField.trackNo || f == MusicTagField.discNo) {
      return int.tryParse(a.trim()) == int.tryParse(b.trim());
    }
    if (f.wire.startsWith('mb_')) {
      return a.trim().toLowerCase() == b.toLowerCase();
    }
    return a.trim() == b;
  }

  return <MusicTagChange>[
    for (final MusicTagField f in MusicTagField.values)
      if (proposed[f] case final String v when !same(f, current[f], v))
        MusicTagChange(
          field: f,
          current: current[f],
          proposed: v,
          locked: lockedFields.contains(f.wire),
        ),
  ];
}

class MusicTagWriteback {
  MusicTagWriteback({required this.database, int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase database;
  final int Function() _clock;

  Future<MusicTagPreview> preview(String trackUid) async {
    final MusicTrackRow? track = await database.getMusicTrack(trackUid);
    if (track == null) {
      return MusicTagPreview(
        trackUid: trackUid,
        path: '',
        changes: const <MusicTagChange>[],
        blockedReason: MusicTagBlocked.notIdentified,
      );
    }
    if (track.cueStartMs != null) {
      return MusicTagPreview(
        trackUid: trackUid,
        path: track.path,
        changes: const <MusicTagChange>[],
        blockedReason: MusicTagBlocked.cueTrack,
      );
    }
    final MusicScrapeMetaRow? meta = await database.getMusicScrapeMeta(
      trackUid,
    );
    if (meta == null || meta.status != 'matched') {
      return MusicTagPreview(
        trackUid: trackUid,
        path: track.path,
        changes: const <MusicTagChange>[],
        blockedReason: MusicTagBlocked.notIdentified,
      );
    }
    final String path = track.path;
    final Map<MusicTagField, String> current;
    try {
      current = await Isolate.run(
        () => MusicTagFieldsIo.instance.read(path),
        debugName: 'music-tag-read',
      );
    } on MusicTagWriteException {
      return MusicTagPreview(
        trackUid: trackUid,
        path: path,
        changes: const <MusicTagChange>[],
        blockedReason: MusicTagBlocked.unreadable,
      );
    }
    final Set<String> locks = await database.listMusicLockedFields(
      entityKind: MusicLockEntity.track,
      entityUid: trackUid,
    );
    return MusicTagPreview(
      trackUid: trackUid,
      path: path,
      changes: diffMusicTags(
        current: current,
        proposed: proposedMusicTags(meta),
        lockedFields: locks,
      ),
    );
  }

  /// 写 [selected] 里的字段；预览里出现但没勾的字段上锁、勾了的解锁。写盘失败抛
  /// [MusicTagWriteException]（锁不变）。
  Future<void> apply(
    MusicTagPreview preview,
    Set<MusicTagField> selected,
  ) async {
    if (!preview.canWrite) return;
    final Map<MusicTagField, String> fields = <MusicTagField, String>{
      for (final MusicTagChange c in preview.changes)
        if (selected.contains(c.field)) c.field: c.proposed,
    };
    final String path = preview.path;
    if (fields.isNotEmpty) {
      await Isolate.run(
        () => MusicTagFieldsIo.instance.write(path, fields),
        debugName: 'music-tag-write',
      );
    }
    final Set<String> locks = await database.listMusicLockedFields(
      entityKind: MusicLockEntity.track,
      entityUid: preview.trackUid,
    );
    for (final MusicTagChange c in preview.changes) {
      if (selected.contains(c.field)) {
        locks.remove(c.field.wire);
      } else {
        locks.add(c.field.wire);
      }
    }
    await database.setMusicLockedFields(
      entityKind: MusicLockEntity.track,
      entityUid: preview.trackUid,
      fields: locks,
      lockedAt: _clock(),
    );
  }
}

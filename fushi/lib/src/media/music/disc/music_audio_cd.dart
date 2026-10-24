/// 音频 CD（音乐方案 §9.2）：桌面物理光驱读 TOC / CD-TEXT（Rust `native/fushi_music`
/// `cd.rs`，Disc ID 也在那边算）→ MusicBrainz Disc ID 查发行 → 曲库里一张带 `CD` 角标的专辑。
///
/// 曲目与 CUE 虚拟曲目同一约定：`path` = `cdda://<设备>`（mpv 的 CD-DA 协议，整张盘一条
/// 时间轴，从第一条音频轨起点算 0），`cue_start_ms` / `cue_end_ms` = 这一轨在盘时间轴上的
/// 起止（帧 → 毫秒，误差 ≤ 0.5 ms）。
///
/// 播放：mpv 的 `cdda://` 不能当 EDL 段的源（与 `dvd://` 同理，盘协议在 EDL 里被拒），只能
/// 用逐文件 `start` / `end` 选项——是播放器级 seek，**轨间不是无缝的**（seek 会清掉设备缓冲
/// 里前一首的尾巴，实测 CUE 场景约 360 ms），见 `mpv_music_output_backend.dart` 文件头。
/// 现随包的 Windows libmpv 没有编 libcdio（`-Dcdda` 未开），`cdda://` 会报「No protocol
/// handler」——读盘、识别、入库可用，播放要等 libmpv 换成带 cdda 的构建。
library;

import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_music/fushi_music.dart';

/// 音频 CD 曲目路径的前缀。
const String kMusicCddaScheme = 'cdda://';

/// 一台光驱上的盘的整盘路径（`cdda://E:`）。
String musicCddaPath(String device) => '$kMusicCddaScheme$device';

bool isMusicCddaPath(String path) => path.startsWith(kMusicCddaScheme);

/// 音频 CD 曲目的 uid：MusicBrainz Disc ID + 轨号（同一张盘在哪台光驱、哪个盘符都一样）。
String musicCdTrackUid(String discId, int trackNumber) =>
    musicDiscChapterTrackUid(
      kind: MusicDiscKind.cdda,
      discId: discId,
      titleNumber: 1,
      chapterNumber: trackNumber,
    );

/// 一次读盘要落库的行（纯换算的产物，可单测）。
class MusicAudioCdRows {
  const MusicAudioCdRows({
    required this.album,
    required this.disc,
    required this.tracks,
  });

  final MusicAlbumsCompanion album;
  final MusicDiscSourcesCompanion disc;
  final List<MusicTracksCompanion> tracks;
}

/// 发行里与这张 CD 对应的那张 medium：轨数相同的第一张（Disc ID 查到的发行，盘位就是它）。
MusicReleaseMedium? musicCdMediumOf(
  MusicReleaseTracklist release,
  AudioCdInfo info,
) {
  final int count = info.audioTracks.length;
  for (final MusicReleaseMedium m in release.media) {
    if (m.tracks.length == count) return m;
  }
  return null;
}

/// 纯换算：一张盘（+ 可选的 MusicBrainz 发行）→ 专辑 / 光盘来源 / 曲目行。名字的优先级：
/// MusicBrainz → CD-TEXT → [fallbackTitle]（本地化的「第 N 轨」）。
MusicAudioCdRows musicAudioCdRows(
  AudioCdInfo info, {
  required String device,
  required String Function(int trackNumber) fallbackTitle,
  required String fallbackAlbumTitle,
  required int now,
  MusicReleaseTracklist? release,
}) {
  final String discId = info.discId!;
  final String albumUid = musicDiscAlbumUid(MusicDiscKind.cdda, discId);
  final String discUid = musicDiscUid(MusicDiscKind.cdda, discId);
  final List<AudioCdTrack> audio = info.audioTracks;
  final int origin = audio.first.lba;
  final MusicReleaseMedium? medium = release == null
      ? null
      : musicCdMediumOf(release, info);
  final List<MusicTracksCompanion> tracks = <MusicTracksCompanion>[];
  for (int i = 0; i < audio.length; i++) {
    final AudioCdTrack t = audio[i];
    final MusicReleaseTrack? mb = medium?.tracks[i];
    final int startMs = ((t.lba - origin) * 1000 / kAudioCdFramesPerSecond)
        .round();
    final bool last = i == audio.length - 1;
    tracks.add(
      MusicTracksCompanion.insert(
        trackUid: musicCdTrackUid(discId, t.number),
        sourceId: const Value<int?>(null),
        path: musicCddaPath(device),
        cueStartMs: Value<int?>(startMs),
        // 末轨播到盘尾（与 CUE 最后一轨同理）。
        cueEndMs: Value<int?>(last ? null : startMs + t.durationMs),
        durationMs: Value<int?>(t.durationMs),
        codec: const Value<String?>('pcm'),
        sampleRate: const Value<int?>(44100),
        bitDepth: const Value<int?>(16),
        channels: const Value<int?>(2),
        bitrate: const Value<int?>(1411),
        isLossless: const Value<bool>(true),
        title:
            _nonEmpty(mb?.title) ??
            info.text(t.number, AudioCdTextField.title) ??
            fallbackTitle(t.number),
        artistCredit: Value<String?>(
          _nonEmpty(mb?.artistCredit) ??
              info.text(t.number, AudioCdTextField.performer) ??
              release?.artistCredit ??
              info.albumPerformer,
        ),
        mbRecordingId: Value<String?>(mb?.mbRecordingId),
        albumUid: Value<String?>(albumUid),
        discNo: Value<int?>(medium?.position),
        trackNo: Value<int?>(t.number),
        fileMtimeAt: 0,
        fileSize: 0,
        addedAt: now,
      ),
    );
  }
  return MusicAudioCdRows(
    album: MusicAlbumsCompanion.insert(
      albumUid: albumUid,
      title: _nonEmpty(release?.title) ?? info.albumTitle ?? fallbackAlbumTitle,
      albumArtistCredit: Value<String?>(
        _nonEmpty(release?.artistCredit) ?? info.albumPerformer,
      ),
      mbReleaseId: Value<String?>(release?.mbReleaseId),
      mbReleaseGroupId: Value<String?>(release?.releaseGroupId),
      releaseDate: Value<String?>(release?.date),
      catalogNo: Value<String?>(
        release == null || release.catalogNumbers.isEmpty
            ? null
            : release.catalogNumbers.first,
      ),
      discUid: Value<String?>(discUid),
      addedAt: now,
      updatedAt: now,
    ),
    disc: MusicDiscSourcesCompanion.insert(
      discUid: discUid,
      path: device,
      kind: MusicDiscKind.cdda.wire,
      volumeId: Value<String?>(discId),
      titleMapJson: Value<String?>(
        encodeMusicDiscTitleMap(<MusicDiscTrackRef>[
          for (final AudioCdTrack t in audio)
            MusicDiscTrackRef(
              trackUid: musicCdTrackUid(discId, t.number),
              titleNumber: 1,
              chapterNumber: t.number,
            ),
        ]),
      ),
      addedAt: now,
    ),
    tracks: tracks,
  );
}

String? _nonEmpty(String? v) {
  final String? t = v?.trim();
  return t == null || t.isEmpty ? null : t;
}

/// 盘里没有音频轨（数据盘）或算不出 Disc ID。
class MusicAudioCdNotAudioException implements Exception {
  const MusicAudioCdNotAudioException(this.device);

  final String device;

  @override
  String toString() => 'MusicAudioCdNotAudioException: $device';
}

typedef MusicAudioCdDriveLister = Future<List<String>> Function();
typedef MusicAudioCdDiscReader = Future<AudioCdInfo> Function(String device);

Future<List<String>> _listDrivesInBackground() => Isolate.run(
  () => AudioCdReader.instance.listDrives(),
  debugName: 'music-cd-drives',
);

Future<AudioCdInfo> _readInBackground(String device) => Isolate.run(
  () => AudioCdReader.instance.read(device),
  debugName: 'music-cd-read',
);

class MusicAudioCdService {
  MusicAudioCdService(
    this._db, {
    MusicAudioCdDriveLister? listDrives,
    MusicAudioCdDiscReader? read,
    int Function()? now,
  }) : _list = listDrives ?? _listDrivesInBackground,
       _read = read ?? _readInBackground,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase _db;
  final MusicAudioCdDriveLister _list;
  final MusicAudioCdDiscReader _read;
  final int Function() _now;

  /// 本机光驱（后台 isolate；光驱读 TOC 会阻塞到盘转起来）。
  Future<List<String>> listDrives() => _list();

  /// 读光驱里的盘。失败抛 `AudioCdReadException`；数据盘抛
  /// [MusicAudioCdNotAudioException]。
  Future<AudioCdInfo> read(String device) async {
    final AudioCdInfo info = await _read(device);
    if (info.discId == null || info.audioTracks.isEmpty) {
      throw MusicAudioCdNotAudioException(device);
    }
    return info;
  }

  /// MusicBrainz Disc ID 查发行（带 TOC 做模糊匹配）。
  Future<List<MusicReleaseTracklist>> lookup(
    AudioCdInfo info,
    MusicReleaseProvider provider,
  ) => provider.lookupDiscId(info.discId!, toc: info.tocQuery);

  /// 落库：专辑 / 光盘来源 / 曲目（同一张盘再读一次覆盖上一次的名字）。返回专辑 uid。
  Future<String> import(
    AudioCdInfo info, {
    required String device,
    required String Function(int trackNumber) fallbackTitle,
    required String fallbackAlbumTitle,
    MusicReleaseTracklist? release,
  }) async {
    final MusicAudioCdRows rows = musicAudioCdRows(
      info,
      device: device,
      fallbackTitle: fallbackTitle,
      fallbackAlbumTitle: fallbackAlbumTitle,
      now: _now(),
      release: release,
    );
    await _db.writeMusicAudioCd(
      album: rows.album,
      disc: rows.disc,
      tracks: rows.tracks,
    );
    return rows.album.albumUid.value;
  }
}

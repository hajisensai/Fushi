import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'audiobook_track_timeline.dart';

/// 远端音频的一条音轨（Audiobookshelf 的一个音频文件）。
///
/// [startOffsetMs] 是该轨在整本书时间轴上的起点（累计值）。整本字幕的时间轴是
/// 全书时间，按它切回各轨内的本地时间，见 `splitCuesAcrossTracks`。
class RemoteAudioTrack {
  const RemoteAudioTrack({
    required this.ino,
    required this.startOffsetMs,
    required this.durationMs,
    this.mimeType,
    this.sizeBytes,
    this.filename,
  });

  final String ino;
  final int startOffsetMs;
  final int durationMs;
  final String? mimeType;
  final int? sizeBytes;
  final String? filename;

  int get endOffsetMs => startOffsetMs + durationMs;

  AudioTrackSpan get span =>
      (startOffsetMs: startOffsetMs, durationMs: durationMs);

  Map<String, Object?> toJson() => <String, Object?>{
    'ino': ino,
    'startOffsetMs': startOffsetMs,
    'durationMs': durationMs,
    if (mimeType != null) 'mime': mimeType,
    if (sizeBytes != null) 'size': sizeBytes,
    if (filename != null) 'filename': filename,
  };

  static RemoteAudioTrack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? ino = raw['ino'];
    final Object? start = raw['startOffsetMs'];
    final Object? duration = raw['durationMs'];
    if (ino is! String || ino.isEmpty || start is! num || duration is! num) {
      return null;
    }
    final Object? mime = raw['mime'];
    final Object? size = raw['size'];
    final Object? filename = raw['filename'];
    return RemoteAudioTrack(
      ino: ino,
      startOffsetMs: start.toInt(),
      durationMs: duration.toInt(),
      mimeType: mime is String ? mime : null,
      sizeBytes: size is num ? size.toInt() : null,
      filename: filename is String ? filename : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteAudioTrack &&
      other.ino == ino &&
      other.startOffsetMs == startOffsetMs &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(ino, startOffsetMs, durationMs);
}

/// 一本字幕书的音频在远端服务器上的绑定（`remote_audio_bindings` 表的领域模型）。
class RemoteAudioBinding {
  const RemoteAudioBinding({
    required this.srtBookUid,
    required this.provider,
    required this.serverConfigId,
    required this.itemId,
    required this.tracks,
    required this.createdAt,
    required this.updatedAt,
    this.episodeId,
    this.subtitleOrigin = subtitleOriginLocal,
  });

  static const String providerAudiobookshelf = 'audiobookshelf';

  /// 字幕是用户选的本机文件。
  static const String subtitleOriginLocal = 'local';

  /// 没挂字幕（纯听书）；之后补上字幕时改成 [subtitleOriginLocal]。
  static const String subtitleOriginNone = 'none';

  /// 字幕来自服务器条目里的文件：`server:<ino>`。
  static String subtitleOriginServer(String ino) => 'server:$ino';

  final String srtBookUid;
  final String provider;
  final String serverConfigId;
  final String itemId;

  /// 播客单集 id；null = 有声书条目本身。
  final String? episodeId;
  final List<RemoteAudioTrack> tracks;
  final String subtitleOrigin;
  final int createdAt;
  final int updatedAt;

  /// 各音轨在全书时间轴上的位置，喂给 [splitCuesAcrossTracks]。
  List<AudioTrackSpan> get spans => <AudioTrackSpan>[
    for (final RemoteAudioTrack t in tracks) t.span,
  ];

  /// 服务器上字幕文件的 ino（`server:<ino>`）；本机文件为 null。
  String? get serverSubtitleIno => subtitleOrigin.startsWith('server:')
      ? subtitleOrigin.substring('server:'.length)
      : null;

  /// 音轨表是否与 [other] 一致（ino、偏移、时长）。服务器重扫后不一致 = 要按新偏移
  /// 重切字幕时间轴。
  bool sameTracksAs(List<RemoteAudioTrack> other) {
    if (other.length != tracks.length) return false;
    for (int i = 0; i < tracks.length; i++) {
      if (tracks[i] != other[i]) return false;
    }
    return true;
  }

  RemoteAudioBinding copyWith({
    List<RemoteAudioTrack>? tracks,
    String? subtitleOrigin,
    int? updatedAt,
  }) => RemoteAudioBinding(
    srtBookUid: srtBookUid,
    provider: provider,
    serverConfigId: serverConfigId,
    itemId: itemId,
    episodeId: episodeId,
    tracks: tracks ?? this.tracks,
    subtitleOrigin: subtitleOrigin ?? this.subtitleOrigin,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static String encodeTracks(List<RemoteAudioTrack> tracks) => jsonEncode(
    <Map<String, Object?>>[for (final RemoteAudioTrack t in tracks) t.toJson()],
  );

  /// 解不出（坏 JSON / 空表）返回 null：调用方把它当「没有绑定」，字幕书退回只有
  /// 字幕的形态，而不是带着一张没有音轨的表去播放。
  static List<RemoteAudioTrack>? decodeTracks(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    final List<RemoteAudioTrack> tracks = <RemoteAudioTrack>[
      for (final Object? entry in decoded)
        if (RemoteAudioTrack.fromJson(entry) case final RemoteAudioTrack t) t,
    ];
    // 有一条解不出就整体作废：缺一轨的偏移表会让后面所有句子错位。
    if (tracks.isEmpty || tracks.length != decoded.length) return null;
    return tracks;
  }

  static RemoteAudioBinding? fromRow(RemoteAudioBindingRow row) {
    final List<RemoteAudioTrack>? tracks = decodeTracks(row.tracksJson);
    if (tracks == null) return null;
    return RemoteAudioBinding(
      srtBookUid: row.srtBookUid,
      provider: row.provider,
      serverConfigId: row.serverConfigId,
      itemId: row.itemId,
      episodeId: row.episodeId,
      tracks: tracks,
      subtitleOrigin: row.subtitleOrigin,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  RemoteAudioBindingsCompanion toCompanion() =>
      RemoteAudioBindingsCompanion.insert(
        srtBookUid: srtBookUid,
        provider: provider,
        serverConfigId: serverConfigId,
        itemId: itemId,
        episodeId: Value<String?>(episodeId),
        tracksJson: encodeTracks(tracks),
        subtitleOrigin: Value<String>(subtitleOrigin),
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

class RemoteAudioBindingRepository {
  const RemoteAudioBindingRepository(this._db);

  final FushiDatabase _db;

  /// 字幕书的远端音频绑定；没有（或行已损坏）为 null。
  Future<RemoteAudioBinding?> get(String srtBookUid) async {
    final RemoteAudioBindingRow? row = await _db.getRemoteAudioBinding(
      srtBookUid,
    );
    return row == null ? null : RemoteAudioBinding.fromRow(row);
  }

  /// 全部有效绑定，按 srtBookUid 索引（书架角标一次读完，不逐本查询）。
  Future<Map<String, RemoteAudioBinding>> listAll() async =>
      <String, RemoteAudioBinding>{
        for (final RemoteAudioBindingRow row
            in await _db.getAllRemoteAudioBindings())
          if (RemoteAudioBinding.fromRow(row) case final RemoteAudioBinding b)
            b.srtBookUid: b,
      };

  /// 某台服务器上某个条目（播客再加单集）已经建好的绑定；没有为 null。书库标签页
  /// 用它避免对同一本书重复导入。绑定表很小（每本流式书一行），直接扫。
  Future<RemoteAudioBinding?> findForItem({
    required String serverConfigId,
    required String itemId,
    String? episodeId,
  }) async {
    for (final RemoteAudioBinding binding in (await listAll()).values) {
      if (binding.serverConfigId == serverConfigId &&
          binding.itemId == itemId &&
          binding.episodeId == episodeId) {
        return binding;
      }
    }
    return null;
  }

  Future<void> save(RemoteAudioBinding binding) =>
      _db.upsertRemoteAudioBinding(binding.toCompanion());

  Future<int> delete(String srtBookUid) =>
      _db.deleteRemoteAudioBinding(srtBookUid);
}

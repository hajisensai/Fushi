import 'dart:convert';

import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;

/// 一条可选外挂音轨对应的 libmpv `audio-add` 调用（EXlaIL2eKQ）。
class VideoExternalAudioAdd {
  const VideoExternalAudioAdd({
    required this.sourceUrl,
    required this.nativeUri,
    required this.title,
    required this.command,
  });

  /// 原始音频地址（制卡从它裁音频）。
  final String sourceUrl;

  /// 交给 mpv 的实际 URI：mpv 原样记进 `track-list` 的 `external-filename`，
  /// [resolveExternalAudioTracks] 据此把挂上的轨认回来源（不靠标题）。
  final String nativeUri;

  /// 交给 mpv 的轨标题（音轨菜单显示用）；同一次 load 内唯一。**不是身份**：流自带
  /// 音轨可能与它同名（例如都叫「Japanese」）。
  final String title;

  /// `audio-add <uri> auto <title> [<lang>]`。
  final List<String> command;
}

/// 纯函数：把可选外挂音轨翻成 `audio-add ... auto` 命令。
///
/// `auto` 而不是 `select`：不强制选中，交给 mpv 默认选轨——流自带音轨时仍放原声
/// （这些是替代配音），DASH 纯视频流没有自带音轨时 mpv 自动选中外挂音频。这与
/// 上游 Aniyomi 对 `Video.audioTracks` 的处理一致。
///
/// 标题取扩展给的标签，缺省时 `External audio N`；外挂轨之间重名补 ` (2)` 之类后缀
/// （菜单里分得清）。
List<VideoExternalAudioAdd> buildExternalAudioAddCommands(
  List<RemoteVideoExternalAudioTrack> tracks, {
  required String Function(String url) nativeUri,
}) {
  final Set<String> used = <String>{};
  final List<VideoExternalAudioAdd> adds = <VideoExternalAudioAdd>[];
  for (int i = 0; i < tracks.length; i++) {
    final RemoteVideoExternalAudioTrack track = tracks[i];
    if (track.url.isEmpty) continue;
    final String base = (track.label ?? '').trim().isNotEmpty
        ? track.label!.trim()
        : 'External audio ${i + 1}';
    String title = base;
    int suffix = 2;
    while (!used.add(title)) {
      title = '$base ($suffix)';
      suffix++;
    }
    final String language = (track.language ?? '').trim();
    final String uri = nativeUri(track.url);
    adds.add(
      VideoExternalAudioAdd(
        sourceUrl: track.url,
        nativeUri: uri,
        title: title,
        command: <String>[
          'audio-add',
          uri,
          'auto',
          title,
          if (language.isNotEmpty) language,
        ],
      ),
    );
  }
  return adds;
}

/// `audio-add` 之后按 mpv `track-list` 认出的结果。
class ExternalAudioTrackResolution {
  const ExternalAudioTrackResolution({
    required this.sourcesByTrackId,
    required this.failed,
    required this.hasOwnAudio,
  });

  /// 真挂上的外挂音轨：mpv 轨 id → 原地址。
  final Map<String, String> sourcesByTrackId;

  /// `track-list` 里找不到的（mpv 打开失败：403 / 失效 / 不支持）。
  final List<VideoExternalAudioAdd> failed;

  /// 主流有没有自带音轨（`track-list` 里有非外挂的音频轨）。
  final bool hasOwnAudio;

  /// 一条外挂音轨都没挂上、主流又没有自带音轨：这次播放必然无声。
  bool get silent => sourcesByTrackId.isEmpty && !hasOwnAudio;
}

/// 纯函数：从 mpv `track-list`（[trackListJson]，`getProperty('track-list')` 的 JSON）
/// 认出 [adds] 各自挂成了哪条轨。身份只认 `external` + `external-filename`
/// （= [VideoExternalAudioAdd.nativeUri]），与轨标题无关；同一 URI 挂了多次时按序
/// 各认一条。JSON 读不懂返回 null（比不出来，不下结论）。
///
/// media_kit 的 `command` 遇到 mpv 错误只记日志、不抛（`_command` 只 `_logError`），
/// 所以「audio-add 是否成功」只能这样事后从 `track-list` 确认。
ExternalAudioTrackResolution? resolveExternalAudioTracks({
  required String trackListJson,
  required List<VideoExternalAudioAdd> adds,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(trackListJson);
  } on FormatException {
    return null;
  }
  if (decoded is! List<Object?>) return null;
  final List<({String id, String? filename})> external =
      <({String id, String? filename})>[];
  bool hasOwnAudio = false;
  for (final Object? entry in decoded) {
    if (entry is! Map<String, Object?> || entry['type'] != 'audio') continue;
    final Object? id = entry['id'];
    if (id is! int) continue;
    if (entry['external'] == true) {
      final Object? filename = entry['external-filename'];
      external.add((id: '$id', filename: filename is String ? filename : null));
    } else {
      hasOwnAudio = true;
    }
  }
  final Map<String, String> sources = <String, String>{};
  final List<VideoExternalAudioAdd> failed = <VideoExternalAudioAdd>[];
  for (final VideoExternalAudioAdd add in adds) {
    final int index = external.indexWhere(
      (({String id, String? filename}) t) =>
          t.filename == add.nativeUri && !sources.containsKey(t.id),
    );
    if (index < 0) {
      failed.add(add);
    } else {
      sources[external[index].id] = add.sourceUrl;
    }
  }
  return ExternalAudioTrackResolution(
    sourcesByTrackId: Map<String, String>.unmodifiable(sources),
    failed: List<VideoExternalAudioAdd>.unmodifiable(failed),
    hasOwnAudio: hasOwnAudio,
  );
}

/// 纯函数：制卡音频该从哪条外挂音轨裁（null = 不是外挂音轨，走原有来源）。身份
/// 一律按 mpv 轨 id（[sourcesByTrackId] 见 [resolveExternalAudioTracks]），不按标题。
///
/// - 选中的轨（[selectedId]，media_kit 已对齐 / 用户显式选过）是外挂音轨 → 它；
/// - 仍是 `auto`（[selectedIsAuto]）且真实音轨全是外挂音轨（纯视频流）→ mpv 的
///   auto 选的必然是外挂音轨里的第一条。
String? externalAudioMiningSource({
  required Map<String, String> sourcesByTrackId,
  required bool selectedIsAuto,
  required String? selectedId,
  required List<String> realTrackIds,
}) {
  if (sourcesByTrackId.isEmpty) return null;
  if (!selectedIsAuto) {
    return selectedId == null ? null : sourcesByTrackId[selectedId];
  }
  if (realTrackIds.isEmpty) return null;
  final bool allExternal = realTrackIds.every(sourcesByTrackId.containsKey);
  return allExternal ? sourcesByTrackId[realTrackIds.first] : null;
}

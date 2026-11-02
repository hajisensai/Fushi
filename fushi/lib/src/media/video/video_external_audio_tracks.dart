import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;

/// 一条可选外挂音轨对应的 libmpv `audio-add` 调用（EXlaIL2eKQ）。
class VideoExternalAudioAdd {
  const VideoExternalAudioAdd({
    required this.sourceUrl,
    required this.title,
    required this.command,
  });

  /// 原始音频地址（制卡从它裁音频）。
  final String sourceUrl;

  /// 交给 mpv 的轨标题；同一次 load 内唯一，用来把 media_kit 的音轨认回来源。
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
/// 标题取扩展给的标签，缺省时 `External audio N`；重名补 ` (2)` 之类后缀，保证
/// 能按标题把选中的轨映射回 [VideoExternalAudioAdd.sourceUrl]。
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
    adds.add(
      VideoExternalAudioAdd(
        sourceUrl: track.url,
        title: title,
        command: <String>[
          'audio-add',
          nativeUri(track.url),
          'auto',
          title,
          if (language.isNotEmpty) language,
        ],
      ),
    );
  }
  return adds;
}

/// 纯函数：制卡音频该从哪条外挂音轨裁（null = 不是外挂音轨，走原有来源）。
///
/// - 选中的轨（[selectedTitle]，media_kit 已对齐 / 用户显式选过）是外挂音轨 → 它；
/// - 仍是 `auto`（[selectedIsAuto]）且真实音轨全是外挂音轨（纯视频流）→ mpv 的
///   auto 选的必然是外挂音轨里的第一条。
String? externalAudioMiningSource({
  required Map<String, String> sourcesByTitle,
  required bool selectedIsAuto,
  required String? selectedTitle,
  required List<String?> realTrackTitles,
}) {
  if (sourcesByTitle.isEmpty) return null;
  if (!selectedIsAuto) {
    return selectedTitle == null ? null : sourcesByTitle[selectedTitle];
  }
  if (realTrackTitles.isEmpty) return null;
  final bool allExternal = realTrackTitles.every(
    (String? title) => title != null && sourcesByTitle.containsKey(title),
  );
  return allExternal ? sourcesByTitle[realTrackTitles.first] : null;
}

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show pickSubtitleSourceByPreference;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show
        SubtitleSource,
        sameExternalSubtitlePathForMenu,
        sameSubtitleFilePath,
        subtitleSourceMatchesPersistedForMenu;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoSidecarSubtitle;

/// 远端视频的「后端默认外挂字幕」从哪个后端来（Xt3RCTPKhX）。
///
/// 远端（`_isRemote`）覆盖互联、Jellyfin / Emby / Plex、在线源扩展、直链流，
/// 不只是互联：行文案按它给，不再一律写「Fushi 互联服务端字幕」。
enum RemoteDefaultSubtitleOrigin {
  interconnect,
  mediaServer,
  onlineSource,
  stream,
}

/// 远端字幕**文件**行的种类。
enum RemoteSubtitleFileKind {
  /// 后端下发的默认外挂字幕（下载到临时目录）：不可删除。
  backendDefault,

  /// 本机落盘的字幕档（在线下载 / 手动导入，`video_subtitles/`）：可长按删除。
  localFile,

  /// 互联 host 上这一集的另一条外挂字幕（`sidecarSubtitles`，反馈 -CaVsioFhG）：
  /// 选中时才按文件名下载，不可删。[RemoteSubtitleFileEntry.path] 是它的选择编码
  /// （[remoteHostSidecarSubtitleSource]），不是本机文件路径。
  hostSidecar,
}

/// host 外挂字幕 [fileName] 的远端选择编码（持久化 / 选中态比对用）。
String remoteHostSidecarSubtitleSource(String fileName) =>
    '${SubtitleSource.hostSidecarPrefix}$fileName';

/// 按选择编码 [source] 在 [sidecars] 里找回那一条 host 外挂字幕；不是该编码 /
/// host 这一集已没有它时返回 null。
RemoteVideoSidecarSubtitle? remoteHostSidecarForSource(
  String? source,
  List<RemoteVideoSidecarSubtitle> sidecars,
) {
  if (!SubtitleSource.isHostSidecarPersisted(source)) return null;
  final String name = source!.substring(
    SubtitleSource.hostSidecarPrefix.length,
  );
  for (final RemoteVideoSidecarSubtitle sidecar in sidecars) {
    if (sidecar.fileName == name) return sidecar;
  }
  return null;
}

/// 远端字幕文件的一行：主字幕菜单、副字幕菜单、手机遥控字幕列表共用。
@immutable
class RemoteSubtitleFileEntry {
  const RemoteSubtitleFileEntry._({
    required this.path,
    required this.label,
    required this.kind,
    this.local,
    this.hostSidecar,
  });

  /// 文件行是本机文件路径；[RemoteSubtitleFileKind.hostSidecar] 行是选择编码
  /// （[remoteHostSidecarSubtitleSource]），选中态与持久化都按它比对。
  final String path;

  /// 文件名（行副标题 / 遥控列表标签）。
  final String label;
  final RemoteSubtitleFileKind kind;

  /// [RemoteSubtitleFileKind.localFile] 时是它的 [SubtitleSource]（删除菜单用）。
  final SubtitleSource? local;

  /// [RemoteSubtitleFileKind.hostSidecar] 时是 host 报的那一条（选中时按它下载）；
  /// [RemoteSubtitleFileKind.backendDefault] 时是并进这一行的 host 默认外挂字幕
  /// （[RemoteVideoSidecarSubtitle.isDefault]，可能为 null），只用于选中态比对。
  final RemoteVideoSidecarSubtitle? hostSidecar;

  /// 这一行是不是当前选择 [current]（主 / 副字幕菜单与手机遥控共用的唯一判据）。
  ///
  /// 后端默认行除了自己的临时档路径，也认 host 默认外挂字幕的选择编码：默认档还没
  /// 下到本地时用户从「host 外挂字幕」行选了它（或上次这样选、重进按名重下），之后
  /// 默认档下好、那一行并进默认行——选中态不能因此丢掉。
  bool isSelectedBy(String? current) {
    final SubtitleSource? source = local;
    if (source != null) {
      return subtitleSourceMatchesPersistedForMenu(source, current);
    }
    if (current == null) return false;
    if (current == path) return true;
    final RemoteVideoSidecarSubtitle? merged = hostSidecar;
    return kind == RemoteSubtitleFileKind.backendDefault &&
        merged != null &&
        current == remoteHostSidecarSubtitleSource(merged.fileName);
  }

  /// 这一行来自后端（互联 host 的默认字幕或其它外挂字幕），按后端来源标注。
  bool get fromBackend => kind != RemoteSubtitleFileKind.localFile;

  bool get deletable => kind == RemoteSubtitleFileKind.localFile;
}

/// 远端字幕文件行的**唯一**拼法（Xt3RCTPKhX）。
///
/// 三份互不覆盖的真相：
/// - [backendDefaultPath]：后端下发的默认外挂字幕（`_remoteSubtitlePath`，只放这一种）；
/// - [hostSidecars]：互联 host 报的这一集**全部**外挂字幕（反馈 -CaVsioFhG；老 host
///   / 其它来源为空）。默认那条（[RemoteVideoSidecarSubtitle.isDefault]）已由
///   [backendDefaultPath] 下到本地时不重复成行；其余每条一行，选中时才下载；
/// - [localFiles]：本机落盘的字幕档（按集持久化，重进 / 换集回来据此重建）。
///
/// 本机档总是成行且可删；后端默认与某条本机档是同一路径时只留本机那行（此前
/// 反过来——留下不可删的「服务端字幕」行、把可删的本机行藏掉，用户就删不掉了）。
List<RemoteSubtitleFileEntry> remoteSubtitleFileEntries({
  required String? backendDefaultPath,
  required List<SubtitleSource> localFiles,
  List<RemoteVideoSidecarSubtitle> hostSidecars =
      const <RemoteVideoSidecarSubtitle>[],
}) {
  final List<RemoteSubtitleFileEntry> entries = <RemoteSubtitleFileEntry>[];
  final String? backend = backendDefaultPath;
  RemoteVideoSidecarSubtitle? defaultSidecar;
  for (final RemoteVideoSidecarSubtitle sidecar in hostSidecars) {
    if (sidecar.isDefault) {
      defaultSidecar = sidecar;
      break;
    }
  }
  if (backend != null &&
      !localFiles.any(
        (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, backend),
      )) {
    entries.add(
      RemoteSubtitleFileEntry._(
        path: backend,
        label: p.basename(backend),
        kind: RemoteSubtitleFileKind.backendDefault,
        hostSidecar: defaultSidecar,
      ),
    );
  }
  for (final RemoteVideoSidecarSubtitle sidecar in hostSidecars) {
    if (sidecar.isDefault && backend != null) continue;
    entries.add(
      RemoteSubtitleFileEntry._(
        path: remoteHostSidecarSubtitleSource(sidecar.fileName),
        label: sidecar.fileName,
        kind: RemoteSubtitleFileKind.hostSidecar,
        hostSidecar: sidecar,
      ),
    );
  }
  for (final SubtitleSource source in localFiles) {
    final String? path = source.externalPath;
    if (path == null) continue;
    entries.add(
      RemoteSubtitleFileEntry._(
        path: path,
        label: source.label,
        kind: RemoteSubtitleFileKind.localFile,
        local: source,
      ),
    );
  }
  return entries;
}

/// 起播时后端默认外挂字幕（互联 host 的 sidecar、媒体服务器的外挂轨……）怎么处理。
enum RemoteBackendDefaultSubtitlePlan {
  /// 后端这一集没有默认字幕。
  none,

  /// 只下载、登记成字幕菜单里的一行，不挂到播放上：用户已有别的选择
  /// （显式关闭 / 内嵌轨 / 本机字幕档 / 预解析轨）。
  listOnly,

  /// 下载并作为本集主字幕起播。
  apply,
}

/// 纯函数：后端默认字幕的**可选**与**是否自动挂上**是两件事（反馈 1QkmT2vVTm）。
///
/// 旧实现只在「没有持久化选择」时才下载后端默认字幕，而 `_remoteSubtitlePath`
/// （菜单「服务端字幕」行的唯一来源）只在那条分支里赋值：用户关过一次字幕、或选过
/// 一次内嵌英文轨，重进后 host 上的日语 sidecar 就从菜单里消失，再也选不回来。
/// 「尊重上次选择」只该决定挂不挂，不该决定列不列。
RemoteBackendDefaultSubtitlePlan planRemoteBackendDefaultSubtitle({
  required bool backendOffersDefault,
  required bool selectionRestored,
  required bool hasPreresolvedCues,
}) {
  if (!backendOffersDefault) return RemoteBackendDefaultSubtitlePlan.none;
  if (selectionRestored || hasPreresolvedCues) {
    return RemoteBackendDefaultSubtitlePlan.listOnly;
  }
  return RemoteBackendDefaultSubtitlePlan.apply;
}

/// 纯函数：远端一集**没有持久化字幕选择**时，起播自动挂哪条字幕轨（反馈 wCQIR4Pvz9）。
///
/// 优先级（高到低），返回 null = 都不命中，调用方落回后端默认外挂字幕
/// （`RemoteVideoStreamUrls.subtitleUrl`，[planRemoteBackendDefaultSubtitle]）：
/// 1. **app 的主字幕语言偏好**（[preferences]，`parseSubtitleLanguagePreferences`
///    解析过的条目）——与本地视频自动抽内封轨同一套判据
///    （[pickSubtitleSourceByPreference]），按条目顺序找第一条命中的轨；
/// 2. **服务器的默认标记**（[RemoteVideoEmbeddedSubtitleTrack.isDefault]，Jellyfin /
///    Emby `IsDefault`）——此前远端完全不看它，服务器标了默认的内嵌字幕起播也不显示。
///
/// 只考虑能转文本的轨（[RemoteVideoEmbeddedSubtitleTrack.isText]）：与本地自动抽取
/// 只挑文本轨一致，图形轨仍需用户手选。
RemoteVideoEmbeddedSubtitleTrack? pickRemoteStartupSubtitleTrack(
  List<RemoteVideoEmbeddedSubtitleTrack> tracks, {
  required List<String> preferences,
}) {
  final List<RemoteVideoEmbeddedSubtitleTrack> text =
      <RemoteVideoEmbeddedSubtitleTrack>[
        for (final RemoteVideoEmbeddedSubtitleTrack t in tracks)
          if (t.isText) t,
      ];
  if (text.isEmpty) return null;
  if (preferences.isNotEmpty) {
    // 轨序号作 streamIndex 编码进 SubtitleSource，命中后按序号取回原轨（各后端的
    // streamIndex 语义不同、不保证唯一，不拿它反查）。
    final List<SubtitleSource> sources = <SubtitleSource>[
      for (int i = 0; i < text.length; i++)
        SubtitleSource.embedded(
          streamIndex: i,
          label: remoteSubtitleTrackPreferenceLabel(text[i]),
          language: text[i].language,
          codec: text[i].codec,
        ),
    ];
    final SubtitleSource? hit = pickSubtitleSourceByPreference(
      sources,
      preferences,
    );
    if (hit != null) return text[hit.streamIndex!];
  }
  for (final RemoteVideoEmbeddedSubtitleTrack t in text) {
    if (t.isDefault) return t;
  }
  return null;
}

/// 远端轨参与偏好匹配的标签：标题（Jellyfin `DisplayTitle` 等，含语言与说明）+ 语言码。
@visibleForTesting
String remoteSubtitleTrackPreferenceLabel(RemoteVideoEmbeddedSubtitleTrack t) =>
    <String>[
      if ((t.title ?? '').trim().isNotEmpty) t.title!.trim(),
      if ((t.language ?? '').trim().isNotEmpty) t.language!.trim(),
    ].join(' ');

/// 纯函数：持久化的本机档路径列表 → 字幕轨列表里的本机档（只留磁盘上还在的）。
/// [exists] 由调用方注入（真实 IO / 测试桩）。顺序保持持久化顺序。
List<SubtitleSource> restoreRemoteLocalSubtitleFiles(
  List<String> persistedPaths, {
  required bool Function(String path) exists,
}) {
  final List<SubtitleSource> restored = <SubtitleSource>[];
  for (final String path in persistedPaths) {
    if (path.isEmpty || !exists(path)) continue;
    if (restored.any(
      (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, path),
    )) {
      continue;
    }
    restored.add(
      SubtitleSource.external(externalPath: path, label: p.basename(path)),
    );
  }
  return restored;
}

/// 纯函数：本机档登记进按集持久化列表（新的在前，按路径去重）。
List<String> addRemoteLocalSubtitleFile(List<String> paths, String path) =>
    <String>[
      path,
      ...paths.where((String e) => !sameSubtitleFilePath(e, path)),
    ];

/// 纯函数：从按集持久化列表移除一个本机档。
List<String> removeRemoteLocalSubtitleFile(List<String> paths, String path) =>
    paths
        .where((String e) => !sameSubtitleFilePath(e, path))
        .toList(growable: false);

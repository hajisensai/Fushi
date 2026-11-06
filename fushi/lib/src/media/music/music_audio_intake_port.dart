/// 音乐库「交接」的窄口：结果类型、迁移用到的三种交接与网络来源根的命名空间写法。
///
/// 具体实现 [MusicAudioIntake]（`music_audio_intake.dart`）编排来源扫描、登记 / 撤掉
/// 来源，是 app 层；启动时的「纯音频视频 → 音乐库」迁移只经这个口交接，由 AppModel
/// 注入实现，迁移本身就不进 AppModel 大环（`test/build/import_cycle_guard_test.dart`）。
library;

import 'package:fushi_core/fushi_core.dart' show decodeSourceConfig;
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';

import 'package:fushi/src/media/source_library/sftp_stream_source.dart'
    show sftpSourceUrlOf, sftpSourceUrlRootForConfig;

/// 一次交接的结果。
class MusicAudioIntakeResult {
  const MusicAudioIntakeResult({
    this.registeredRoots = const <PlannedMusicRoot>[],
    this.retiredSourceIds = const <int, OwnedMusicRootRetireReason>{},
    this.updatedSourceIds = const <int>[],
    this.importedFiles = const <String>[],
    this.rescannedSourceIds = const <int>[],
    this.skippedPaths = const <String>[],
    this.errors = const <String>[],
  });

  /// 新登记的常驻音乐来源（「仅此一次」交接时是一次性导入的目录）。
  final List<PlannedMusicRoot> registeredRoots;

  /// 对账时撤掉的自动来源（id → 原因）。
  final Map<int, OwnedMusicRootRetireReason> retiredSourceIds;

  /// 对账时改了「含子文件夹」并重扫的自动来源。
  final List<int> updatedSourceIds;

  /// 逐个「仅此一次」导入的文件。
  final List<String> importedFiles;

  /// 因为覆盖了交来的文件而重扫的音乐来源。
  final List<int> rescannedSourceIds;

  /// 没收的（不是本地纯音频、与视频同目录）。
  final List<String> skippedPaths;

  /// 扫描错误摘要（每个来源 / 文件一条）。
  final List<String> errors;

  /// 交来的文件里有多少被送进了音乐库的扫描。
  bool get handedOver =>
      registeredRoots.isNotEmpty ||
      importedFiles.isNotEmpty ||
      rescannedSourceIds.isNotEmpty;
}

/// [MusicAudioIntake] 对外的交接（语义见实现）。
abstract interface class MusicAudioIntakePort {
  /// 本地视频来源扫到的纯音频：按目录登记常驻音乐来源（[oneShot] 时一次性导入）。
  Future<MusicAudioIntakeResult> adoptVideoSourceAudio({
    required SourceLibraryRow owner,
    required List<String> audioPaths,
    required Iterable<String> videoMediaDirs,
    Iterable<String> videoFilePaths,
    bool reconcile,
    bool oneShot,
  });

  /// 网络视频来源扫到的纯音频：在同一台服务器上登记网络音乐来源。
  Future<MusicAudioIntakeResult> adoptRemoteVideoSourceAudio({
    required SourceLibraryRow videoSource,
    required String scanRoot,
    required List<String> audioPaths,
    required Iterable<String> videoMediaDirs,
    Iterable<String> videoFilePaths,
    bool rescanCoveringSources,
  });

  /// 不属于任何来源的零散音频文件：逐个导入（或重扫已覆盖它的音乐来源）。
  Future<MusicAudioIntakeResult> importAudioFiles(Iterable<String> paths);
}

/// 网络来源 [source] 的根在库内命名空间里的写法（与它扫出的条目 / 视频行路径同一口径）：
/// SFTP 换成 `sftp://主机:端口/远端路径` 稳定地址，WebDAV / AList 的根本身就是地址。
String remoteSourceNamespacedRoot(SourceLibraryRow source) {
  if (source.transport != 'sftp') return source.rootPath;
  return sftpSourceUrlOf(
    source.rootPath,
    sftpSourceUrlRootForConfig(decodeSourceConfig(source.configJson)),
  );
}

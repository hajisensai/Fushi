/// 有声书 / 字幕书登记的**用户本机原始音频文件**：判据、解析与删除。
/// 只服务删除确认框的「同时删除本地文件」，与播放装载是两条独立解析。
///
/// ## 为什么不复用播放解析
///
/// 播放解析（`audiobook_playback_files.dart` 的 [resolveAudiobookPlaybackFiles]）
/// 在 `audioPaths` 为空时会枚举 `audioRoot` 目录里的全部音频文件。那回答的是
/// 「这个目录里有什么」，不是「这条记录拥有什么」。读的范围可以宽松，删的不行：
/// 旧版按目录导入的年代，一个文件夹放多本书是常规用法，拿目录清扫当删除判据就是
/// 删 A 连 B 的音频一起没，B 还留在架上变成打不开的壳。
///
/// ## 可删清单的两条判据（必须同时成立）
///
/// 1. **路径来自显式登记的 `audioPaths`**。它是「这本书用了哪几个文件」的唯一
///    真相源——`AudioCue.audioFileIndex` 就是这张表的下标。纯 `audioRoot` 的旧行
///    没有这张表：目录里哪些文件属于这本书从来没被记下来过。这种行返回空表，
///    界面上因此**不摆**删除勾选框。「这条记录没有可安全删除的文件清单」是一个
///    要如实承认的状态，不是一个要现编目录清扫补上的缺口。
/// 2. **路径落在 app 有声书持久根之外**（[AudiobookStorage.isReferencedPath]）。
///    落在里面的是导入时 app 自己复制的副本，`deletePersistDir` 已经负责回收它，
///    不是用户的原件。桌面端不勾「引用原文件」导入的书，`audioPaths` 存的全是
///    副本路径——这类书没有任何用户原件可删，同样不该摆勾选框。
///
/// 相对路径一律拒绝：`File(path).delete()` 会按进程 cwd 解析，删掉哪个文件取决于
/// app 当时的工作目录，那不是一个可以对用户负责的判据。
library;

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, deleteLocalFiles;
import 'package:path/path.dart' as p;

import 'audiobook_storage.dart';

/// 纯函数：这条记录里**可安全删除的用户原件**路径（保持登记顺序、去重）。
/// 判据见库文档；不满足任一条的路径直接不出现在结果里。
///
/// [persistRoot] 是 `<documents>/audiobooks` 绝对路径（[AudiobookStorage
/// .audiobooksRootDir]）；解析不出来时传空串，本函数返回空表——判不出「是不是
/// app 副本」时一个文件都不删，是这里唯一可接受的失败方向。
List<String> audiobookLocalFilePaths({
  required List<String>? audioPaths,
  required String persistRoot,
}) {
  if (audioPaths == null || audioPaths.isEmpty) return const <String>[];
  if (persistRoot.trim().isEmpty) return const <String>[];
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String raw in audioPaths) {
    final String path = raw.trim();
    if (path.isEmpty || !p.isAbsolute(path)) continue;
    if (!AudiobookStorage.isReferencedPath(
      filePath: path,
      persistRoot: persistRoot,
    )) {
      continue;
    }
    if (seen.add(p.canonicalize(path))) out.add(path);
  }
  return out;
}

/// 纯函数：这条记录有没有可删的用户原件——删除确认框据此决定摆不摆
/// 「同时删除本地文件」勾选框。
bool audiobookHasLocalFiles({
  required List<String>? audioPaths,
  required String persistRoot,
}) =>
    audiobookLocalFilePaths(
      audioPaths: audioPaths,
      persistRoot: persistRoot,
    ).isNotEmpty;

/// [audiobookLocalFilePaths] 的取根版本（持久根从 [AudiobookStorage] 现取）。
Future<List<String>> resolveAudiobookLocalFiles(
  List<String>? audioPaths,
) async =>
    audiobookLocalFilePaths(
      audioPaths: audioPaths,
      persistRoot: await AudiobookStorage.audiobooksRootDir(),
    );

/// [audiobookHasLocalFiles] 的取根版本。
Future<bool> resolveAudiobookHasLocalFiles(List<String>? audioPaths) async =>
    (await resolveAudiobookLocalFiles(audioPaths)).isNotEmpty;

/// 删除这条记录的用户原件，逐条结果原样回传（失败不吞、不抛）。
/// 调用方负责记 ErrorLog 并把失败条数告诉用户——最常见的失败就是「这本正在播放」。
Future<LocalFileDeleteReport> deleteAudiobookLocalFiles(
  List<String>? audioPaths,
) async =>
    deleteLocalFiles(await resolveAudiobookLocalFiles(audioPaths));

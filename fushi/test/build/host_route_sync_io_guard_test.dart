import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 互联 host 路由处理代码禁止同步文件 IO（BUG-5606）。
///
/// app 当 host 时 `FushiSyncServer` 与 `LocalLibraryHostService` 跑在 UI isolate 上：
/// 路由里一个 `existsSync` / `readAsStringSync` / `statSync` 在冷目录、网络盘
/// （BUG-3756）或大书库上就是一次界面冻结，iPhone 连过来同步时电脑界面一卡一卡。
///
/// 扫描范围是 host 路由可达的处理代码本身：`fushi_sync_server.dart` + 它的 part、
/// `local_library_host_service.dart` + 它的 part。查两类：
///
/// 1. 名字以 `Sync` 结尾的调用（`dart:io` 同步方法与仓里同步形态 helper 的命名）；
/// 2. 已知「内部做同步文件 IO」的判据 / 打包函数被直接调用（它们本身是同步的，
///    给后台 isolate 与非 host 调用方用）。
///
/// 确实只能同步做的探测放进 `host_background_io.dart`（每个入口都经 `Isolate.run`），
/// 或用对应的异步形态（`resolveEpubCoverFilePathAsync`、
/// `hasExportablePdfContentAsync`、`MangaStorage.resolvePageFilePathAsync`）。
void main() {
  const String engineSync = '../packages/fushi_engine/lib/sync';

  List<File> scopedFiles() => <File>[
    File('$engineSync/fushi_sync_server.dart'),
    ...Directory('$engineSync/fushi_sync_server').listSync().whereType<File>(),
    File('$engineSync/local_library_host_service.dart'),
    ...Directory(
      '$engineSync/local_library_host_service',
    ).listSync().whereType<File>(),
  ].where((File f) => f.path.endsWith('.dart')).toList();

  /// 名字以 `Sync` 结尾的调用：`dart:io` 的同步方法（`existsSync` / `statSync` /
  /// `readAsStringSync` …）与仓里同步形态的 helper（`hasLocalMediaFileSync` …）都是
  /// 这个命名。名字碰巧以 Sync 结尾、但与文件 IO 无关的函数登记在 [syncNamedAllowed]。
  final RegExp syncIo = RegExp(r'(?<![\w])(\w+Sync)\(');
  const Set<String> syncNamedAllowed = <String>{
    // 合集同步收敛（同步 = sync 轮次，不是同步 IO）。
    'convergeCollectionsAfterSync',
  };

  /// 内部做同步文件 IO 的判据 / 打包 / 清理函数（直接调用即违规）。
  final RegExp syncHelpers = RegExp(
    r'(?<![\w.])(resolveEpubCoverFilePath|resolveExtractedEpubRoot|'
    r'hasExportableMangaContent|readExportableMangaPayload|'
    r'hasExportablePdfContent|hasExportablePdfFile|hasAnyChapterDirSync|'
    r'pruneOnlineMangaPageCache)\(|MangaStorage\.resolvePageFilePath\(',
  );

  test('host 路由处理代码零同步文件 IO', () {
    final List<File> files = scopedFiles();
    expectScanScale(
      files.length,
      what: 'host 路由处理文件（fushi_sync_server* + local_library_host_service*）',
      atLeast: 20,
      measured: 24,
    );
    final List<String> offenders = <String>[];
    for (final File f in files) {
      final List<String> lines = maskComments(
        f.readAsStringSync(),
      ).split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        for (final RegExpMatch m in <RegExpMatch>[
          ...syncIo
              .allMatches(line)
              .where((RegExpMatch m) => !syncNamedAllowed.contains(m.group(1))),
          ...syncHelpers.allMatches(line),
        ]) {
          offenders.add('${f.path}:${i + 1}: ${m.group(0)}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'host 路由在 app 里跑在 UI isolate 上，同步文件 IO 会冻结界面。改用异步 '
          'API，或把整批探测放进 host_background_io.dart 的 Isolate.run 入口。',
    );
  });

  test('守卫的两条正则确实认得出违规写法（防正则写坏后恒绿）', () {
    expect(syncIo.hasMatch('if (File(p).existsSync()) {'), isTrue);
    expect(syncIo.hasMatch('final s = f.statSync();'), isTrue);
    expect(syncIo.hasMatch('await f.exists()'), isFalse);
    expect(syncIo.hasMatch('hasLocalMediaFileSync(path)'), isTrue);
    expect(
      syncHelpers.hasMatch('resolveEpubCoverFilePath(extractDir: d'),
      isTrue,
    );
    expect(syncHelpers.hasMatch('hasExportablePdfContent(row)'), isTrue);
    expect(syncHelpers.hasMatch('hasExportablePdfContentAsync(row)'), isFalse);
    expect(
      syncHelpers.hasMatch('resolveEpubCoverFilePathAsync(extractDir: d'),
      isFalse,
    );
    expect(
      syncHelpers.hasMatch('MangaStorage.resolvePageFilePath(root, rel)'),
      isTrue,
    );
    expect(
      syncHelpers.hasMatch('MangaStorage.resolvePageFilePathAsync(root, rel)'),
      isFalse,
    );
  });
}

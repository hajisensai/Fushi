// 反馈 HfXM-ECaE8：iOS 单个导入的视频过一阵变成「找不到文件」。
//
// 根因：视频导入 / 播放页「重新选择文件」用丢掉出处的 `pickRealFilePath`，把 iOS
// file_picker import 模式交回的 `NSTemporaryDirectory()` 临时副本（安卓降级时是 app
// cache 副本）原样写进 `VideoBooks.videoPath`；系统清 tmp 或词典导入调
// `FilePicker.clearTemporaryFiles()` 后路径失效。修复：持久化前经
// `adoptPickedVideoCopy` 把临时副本挪进 `<support>/imported_videos/<bookUid>/`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show adoptPickedVideoCopy, isPickerImportCopyPath;
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory pickerTmp;
  late Directory copiesRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('picked_video_adopt_');
    pickerTmp = await Directory(p.join(sandbox.path, 'tmp')).create();
    copiesRoot = Directory(p.join(sandbox.path, 'support', 'imported_videos'));
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<File> pickerCopy(String name, String content) async {
    final File f = File(p.join(pickerTmp.path, name));
    await f.writeAsString(content);
    return f;
  }

  test('临时副本被挪进持久目录：返回新路径、内容不变、原 tmp 副本已移走', () async {
    final File picked = await pickerCopy('E01.mkv', 'video-bytes');

    final String stored = await adoptPickedVideoCopy(
      pickedPath: picked.path,
      isRealPath: false,
      bookUid: 'video/E01',
      copiesRoot: copiesRoot,
    );

    expect(p.isWithin(copiesRoot.path, stored), isTrue);
    expect(p.basename(stored), 'E01.mkv');
    // bookUid 里的 `/` 不能变成额外的目录层级。
    expect(p.dirname(p.dirname(stored)), copiesRoot.path);
    expect(await File(stored).readAsString(), 'video-bytes');
    expect(await picked.exists(), isFalse);
    // 删条目时 BUG-2863 的副本回收仍然命中新位置。
    expect(isPickerImportCopyPath(stored, <String>[copiesRoot.path]), isTrue);
  });

  test('真实路径原样返回，不移动也不复制', () async {
    final File original = await pickerCopy('E02.mkv', 'original');

    final String stored = await adoptPickedVideoCopy(
      pickedPath: original.path,
      isRealPath: true,
      bookUid: 'video/E02',
      copiesRoot: copiesRoot,
    );

    expect(stored, original.path);
    expect(await original.exists(), isTrue);
    expect(await copiesRoot.exists(), isFalse);
  });

  test('同 bookUid 同名旧副本（重新选择文件）被新副本替换', () async {
    final File first = await pickerCopy('E03.mkv', 'old');
    final String firstStored = await adoptPickedVideoCopy(
      pickedPath: first.path,
      isRealPath: false,
      bookUid: 'video/E03',
      copiesRoot: copiesRoot,
    );
    final File second = await pickerCopy('E03.mkv', 'new');

    final String secondStored = await adoptPickedVideoCopy(
      pickedPath: second.path,
      isRealPath: false,
      bookUid: 'video/E03',
      copiesRoot: copiesRoot,
    );

    expect(secondStored, firstStored);
    expect(await File(secondStored).readAsString(), 'new');
    expect(await second.exists(), isFalse);
  });

  test('持久副本目录默认登记在 pickerImportCopyDirectories 里', () async {
    final EnginePaths paths = FixedEnginePaths(
      documents: Directory(p.join(sandbox.path, 'documents')),
      support: Directory(p.join(sandbox.path, 'support')),
      temp: Directory(p.join(sandbox.path, 'cache')),
    );

    final Directory copies = await paths.pickedVideoCopiesDirectory();
    expect(copies.path, copiesRoot.path);
    expect(
      (await paths.pickerImportCopyDirectories()).map((Directory d) => d.path),
      contains(copiesRoot.path),
    );
  });

  test('源码守卫：持久化 videoPath 的拾取点不得用丢出处的 pickRealFilePath', () {
    const List<String> persistingPickers = <String>[
      'lib/src/media/video/video_import_dialog.dart',
      'lib/src/pages/implementations/video_fushi_page.dart',
    ];
    final RegExp lossyCall = RegExp(r'\bpickRealFilePath\(');
    for (final String rel in persistingPickers) {
      final String src = File(rel).readAsStringSync();
      expect(
        lossyCall.hasMatch(src),
        isFalse,
        reason: '$rel 仍调 pickRealFilePath',
      );
      expect(
        src.contains('adoptPickedVideoCopy('),
        isTrue,
        reason: '$rel 落库前必须经 adoptPickedVideoCopy 处理临时副本',
      );
    }
  });
}

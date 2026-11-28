import 'dart:io';

import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// D1：`ServerPaths` 的子目录改由区域登记表（[kServerStorageAreas]）派生。服务端
/// `data_dir` 的磁盘布局是现网格式，这里把切换前的路径原样钉住。
void main() {
  const String root = '/srv/fushi';
  final ServerPaths paths = ServerPaths(root);

  test('登记表构造得出来', () {
    expect(kServerStorageAreas.areas, isNotEmpty);
  });

  test('布局与切换前逐字节一致', () {
    expect(paths.syncData.path, p.join(root, 'interconnect'));
    expect(
      paths.mangaOcrJobs.path,
      p.join(root, 'interconnect', 'manga_ocr_jobs'),
    );
    expect(paths.hostJobs.path, p.join(root, 'support', 'host_jobs'));
    expect(
      paths.dictionaryResources.path,
      p.join(root, 'support', 'dictionaries'),
    );
    expect(paths.logs.path, p.join(root, 'logs'));
    expect(
      paths.interconnectProfiles.path,
      p.join(root, 'support', 'interconnect_profiles'),
    );
    expect(
      paths.torrentResume.path,
      p.join(root, 'support', 'torrent', 'resume'),
    );
  });

  test('ensureLayout 建的目录集合不变', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('srv_layout');
    addTearDown(() => tmp.delete(recursive: true));
    final ServerPaths real = ServerPaths(tmp.path);
    await real.ensureLayout();
    final Set<String> created = <String>{
      for (final FileSystemEntity e in tmp.listSync(recursive: true))
        if (e is Directory) p.relative(e.path, from: tmp.path),
    };
    expect(created, <String>{
      'documents',
      'support',
      'tmp',
      'interconnect',
      p.join('support', 'host_jobs'),
      p.join('support', 'dictionaries'),
      'logs',
    });
  });

  test('引擎共用区域在服务端与 app 同形', () async {
    expect(
      (await paths.videoCoversDirectory()).path,
      p.join(root, 'documents', 'video_covers'),
    );
    expect(
      (await paths.pickedVideoCopiesDirectory()).path,
      p.join(root, 'support', 'imported_videos'),
    );
  });
}

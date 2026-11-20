// 来源扫描的列目录过滤 + 归类在后台 isolate 跑（#3722 m2 gap-scanner-5）。
//
// 合成 3.2 万文件 / 3000 卷的漫画来源上，这三步纯函数同步跑约 270 ms（JIT），
// 扫描期间 UI isolate 连掉十几帧；搬到 [Isolate.run] 后调用方只剩约 3 ms 的
// 消息拷贝。这里钉两件事：后台版本与同步管线逐项一致（含暂存目录 / 垃圾条目过滤），
// 以及扫描主流程只经后台入口归类，不再在调用方 isolate 直接跑 planScanFromFileList。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:path/path.dart' as p;

SourceFileEntry _file(String path) =>
    SourceFileEntry(name: p.basename(path), path: path, isDirectory: false);

void main() {
  group('classifySourceListingInBackground', () {
    test('漫画来源：后台结果与同步管线一致，暂存目录与垃圾条目被滤掉', () async {
      final String root = p.join(p.current, 'lib_manga');
      final List<SourceFileEntry> listed = <SourceFileEntry>[
        for (int s = 0; s < 20; s++)
          for (int v = 0; v < 3; v++)
            _file(p.join(root, 'Archive $s', 'Archive $s Vol $v.cbz')),
        for (int s = 0; s < 10; s++)
          for (int v = 0; v < 2; v++)
            for (int pg = 0; pg < 4; pg++)
              _file(p.join(root, 'Folder $s', 'Vol $v', '00$pg.jpg')),
        _file(p.join(root, '.fushi-incoming', 'manga', 'half.cbz')),
        _file(p.join(root, r'$RECYCLE.BIN', 'old.cbz')),
        _file(p.join(root, 'Archive 0', '._Archive 0 Vol 0.cbz')),
        _file(p.join(root, '@eaDir', 'Folder 0', '000.jpg')),
      ];

      final List<SourceFileEntry> syncEntries = excludeSourceJunkEntries(
        excludeSourceIncomingEntries(listed, sourceRoot: root, isLocal: true),
        scanRoot: root,
      );
      final ScanPlan syncPlan = planScanFromFileList(
        syncEntries,
        mangaRootPath: root,
      );

      final ({List<SourceFileEntry> entries, ScanPlan plan}) bg =
          await classifySourceListingInBackground(
            listed,
            sourceRoot: root,
            scanRoot: root,
            isLocal: true,
            mangaRootPath: root,
          );

      expect(
        bg.entries.map((SourceFileEntry e) => e.path).toList(),
        syncEntries.map((SourceFileEntry e) => e.path).toList(),
      );
      expect(bg.entries, hasLength(listed.length - 4));
      expect(bg.plan.mangaFolders, syncPlan.mangaFolders);
      expect(bg.plan.mangaFolders, hasLength(20));
      expect(
        bg.plan.mangaArchives.map((ScanMangaArchiveItem i) => i.archivePath),
        syncPlan.mangaArchives.map((ScanMangaArchiveItem i) => i.archivePath),
      );
      expect(bg.plan.mangaArchives, hasLength(60));
    });

    test('网络视频来源：p.url 路径语义与同步管线一致，暂存目录不滤（非本地）', () async {
      const String root = '/remote/videos';
      final List<SourceFileEntry> listed = <SourceFileEntry>[
        _file('/remote/videos/Show/ep01.mkv'),
        _file('/remote/videos/Show/ep01.ass'),
        _file('/remote/videos/Show/song.flac'),
        _file('/remote/videos/.fushi-incoming/video/x.mkv'),
        _file('/remote/videos/#recycle/old.mkv'),
      ];
      final List<SourceFileEntry> syncEntries = excludeSourceJunkEntries(
        excludeSourceIncomingEntries(listed, sourceRoot: root, isLocal: false),
        scanRoot: root,
      );
      final ScanPlan syncPlan = planScanFromFileList(
        syncEntries,
        mangaPathContext: p.url,
        bookPathContext: p.url,
        collectPureAudio: true,
      );

      final ({List<SourceFileEntry> entries, ScanPlan plan}) bg =
          await classifySourceListingInBackground(
            listed,
            sourceRoot: root,
            scanRoot: root,
            isLocal: false,
            pathContext: p.url,
            collectPureAudio: true,
          );

      expect(
        bg.entries.map((SourceFileEntry e) => e.path).toList(),
        syncEntries.map((SourceFileEntry e) => e.path).toList(),
      );
      expect(bg.plan.videos, syncPlan.videos);
      expect(
        bg.plan.videos.map((ScanVideoItem v) => v.videoPath).toSet(),
        <String>{
          '/remote/videos/Show/ep01.mkv',
          '/remote/videos/.fushi-incoming/video/x.mkv',
        },
      );
      expect(bg.plan.pureAudioPaths, syncPlan.pureAudioPaths);
      expect(bg.plan.pureAudioPaths, <String>['/remote/videos/Show/song.flac']);
    });
  });

  test('扫描主流程只经后台入口归类，不在调用方 isolate 直接跑 planScanFromFileList', () {
    final String src = File(
      'lib/src/media/source_library/source_library_scanner.dart',
    ).readAsStringSync();
    const String helperEnd = "debugName: 'source-scan-classify'";
    final int end = src.indexOf(helperEnd);
    expect(end, isNonNegative, reason: '后台归类入口不见了');
    final String rest = src.substring(end + helperEnd.length);
    expect(
      rest.contains('planScanFromFileList('),
      isFalse,
      reason: '扫描流程又在调用方 isolate 同步归类了（大来源上卡 UI 几百毫秒）',
    );
    expect(rest.contains('await classifySourceListingInBackground('), isTrue);
  });
}

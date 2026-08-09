// TODO-1961：下载目录可配置。核心不变量——**改目录只影响新增任务**：
//   ① 新任务落到新根；
//   ② 旧任务留在旧根，且下载页的分类过滤必须**同时**认旧根与新根，
//      否则用户一改目录，正在跑的任务整批消失、随后被判超时失败。
// 这些是纯路径逻辑，不需要 libtorrent DLL，所以能在 CI 上真跑（内置引擎的行为层
// 测试要真 DLL + 做种夹具，CI 上多半 skip，守不住这条）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/download_save_root.dart';
import 'package:path/path.dart' as p;

void main() {
  group('TorrentSaveRoots 认根规则', () {
    test('未配置时活动根 = 默认根，行为与可配置之前一致', () {
      final TorrentSaveRoots roots = resolveTorrentSaveRoots(
        defaultRoot: p.join('C:', 'docs', 'anime_downloads', 'content'),
        configuredRoot: '',
      );
      expect(roots.active,
          p.normalize(p.join('C:', 'docs', 'anime_downloads', 'content')));
      expect(roots.legacy, isEmpty, reason: '默认根就是活动根，不该再重复进历史根');
      expect(
        roots.categoryPathFor('hibiki'),
        p.join('C:', 'docs', 'anime_downloads', 'content', 'hibiki'),
      );
    });

    test('改目录后：新任务落新根，旧根仍被认（旧任务不丢）', () {
      final String oldRoot = p.join('C:', 'docs', 'anime_downloads', 'content');
      final String newRoot = p.join('D:', 'media', 'downloads');
      final TorrentSaveRoots roots = resolveTorrentSaveRoots(
        defaultRoot: oldRoot,
        configuredRoot: newRoot,
      );

      // ① 写入只用新根。
      expect(roots.active, p.normalize(newRoot));
      expect(roots.categoryPathFor('hibiki'), p.join(newRoot, 'hibiki'));

      // ② 两个根的同名分类目录都认。
      expect(
          roots.ownsCategoryPath(p.join(newRoot, 'hibiki'), 'hibiki'), isTrue,
          reason: '新根下的新任务必须可见');
      expect(
          roots.ownsCategoryPath(p.join(oldRoot, 'hibiki'), 'hibiki'), isTrue,
          reason: 'TODO-1961 回归：改目录后旧根任务从下载页整批消失');

      // 别的分类仍然不认（过滤没被放宽成「什么都算我的」）。
      expect(
          roots.ownsCategoryPath(p.join(newRoot, 'other'), 'hibiki'), isFalse);
      expect(
          roots.ownsCategoryPath(p.join(oldRoot, 'other'), 'hibiki'), isFalse);
      // 根本身（分类目录的父级）不算。
      expect(roots.ownsCategoryPath(newRoot, 'hibiki'), isFalse);
    });

    test('改多次目录：每一代旧根都还认得', () {
      final String root0 = p.join('C:', 'docs', 'content');
      final String root1 = p.join('D:', 'one');
      final String root2 = p.join('E:', 'two');
      final TorrentSaveRoots roots = resolveTorrentSaveRoots(
        defaultRoot: root0,
        configuredRoot: root2,
        history: <String>[root1],
      );
      for (final String root in <String>[root0, root1, root2]) {
        expect(roots.ownsCategoryPath(p.join(root, 'hibiki'), 'hibiki'), isTrue,
            reason: '历史根必须仍被认');
      }
      expect(roots.active, p.normalize(root2));
    });

    test('withActive 把旧活动根降级为历史根，不丢任何一代', () {
      final TorrentSaveRoots first =
          TorrentSaveRoots(active: p.join('C:', 'a'));
      final TorrentSaveRoots second = first.withActive(p.join('D:', 'b'));
      final TorrentSaveRoots third = second.withActive(p.join('E:', 'c'));
      expect(third.active, p.normalize(p.join('E:', 'c')));
      expect(third.all.length, 3);
      for (final List<String> parts in <List<String>>[
        <String>['C:', 'a'],
        <String>['D:', 'b'],
        <String>['E:', 'c'],
      ]) {
        expect(
          third.ownsCategoryPath(
              p.join(parts[0], parts[1], 'hibiki'), 'hibiki'),
          isTrue,
        );
      }
      // 换回同一个根是空操作，不会把自己塞进历史。
      expect(third.withActive(p.join('E:', 'c')).all.length, 3);
    });

    test('分类目录下的子文件夹仍算本任务（用户整理内容后不蒸发）', () {
      final TorrentSaveRoots roots =
          TorrentSaveRoots(active: p.join('D:', 'dl'));
      expect(
        roots.ownsCategoryPath(p.join('D:', 'dl', 'hibiki', 'S1'), 'hibiki'),
        isTrue,
      );
      // 相邻的同前缀分类不能被误认（段级比较，不是裸 startsWith）。
      expect(
        roots.ownsCategoryPath(p.join('D:', 'dl', 'hibiki-anime'), 'hibiki'),
        isFalse,
      );
    });

    test('构造去重 + 规范化（尾斜杠 / . 段不产生重复根）', () {
      final String active = p.join('D:', 'dl') + p.separator;
      final TorrentSaveRoots roots = TorrentSaveRoots(
        active: active,
        legacy: <String>[
          p.join('D:', 'dl'),
          p.join('C:', 'old', '.'),
          p.join('C:', 'old'),
          '',
          '   ',
        ],
      );
      expect(roots.active, p.normalize(p.join('D:', 'dl')));
      expect(roots.legacy, <String>[p.normalize(p.join('C:', 'old'))]);
    });

    test('历史根有上限，不会无限增长', () {
      TorrentSaveRoots roots = TorrentSaveRoots(active: p.join('D:', 'r0'));
      for (int i = 1; i <= kMaxSaveRootHistory + 5; i++) {
        roots = roots.withActive(p.join('D:', 'r$i'));
      }
      expect(roots.legacy.length, kMaxSaveRootHistory);
    });
  });

  group('历史根编解码', () {
    test('round-trip 去重且截断', () {
      final String encoded = encodeSaveRootHistory(<String>[
        p.join('D:', 'a'),
        p.join('D:', 'a') + p.separator,
        p.join('D:', 'b'),
        '',
      ]);
      expect(decodeSaveRootHistory(encoded), <String>[
        p.normalize(p.join('D:', 'a')),
        p.normalize(p.join('D:', 'b')),
      ]);
    });

    test('畸形输入当空，绝不抛', () {
      expect(decodeSaveRootHistory(''), isEmpty);
      expect(decodeSaveRootHistory('   '), isEmpty);
      expect(decodeSaveRootHistory('not json'), isEmpty);
      expect(decodeSaveRootHistory('{"a":1}'), isEmpty);
      expect(decodeSaveRootHistory('[1, null, "", "  "]'), isEmpty);
    });
  });

  group('checkDownloadSaveRoot 目录可用性', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_dl_root_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发句柄未释放；留给系统临时目录清理。
      }
    });

    test('已存在且可写 → null', () async {
      expect(await checkDownloadSaveRoot(tempDir.path), isNull);
    });

    test('不存在但能建出来 → null 且真的建了', () async {
      final String target = p.join(tempDir.path, 'new', 'nested');
      expect(await checkDownloadSaveRoot(target), isNull);
      expect(Directory(target).existsSync(), isTrue);
    });

    test('探针文件用完即删，不给用户留垃圾', () async {
      expect(await checkDownloadSaveRoot(tempDir.path), isNull);
      expect(File(p.join(tempDir.path, '.hibiki_write_probe')).existsSync(),
          isFalse);
    });

    test('空串 / 相对路径 → notAbsolute（不静默接受）', () async {
      expect(
          await checkDownloadSaveRoot(''), DownloadSaveRootIssue.notAbsolute);
      expect(await checkDownloadSaveRoot('   '),
          DownloadSaveRootIssue.notAbsolute);
      expect(await checkDownloadSaveRoot(p.join('relative', 'dir')),
          DownloadSaveRootIssue.notAbsolute);
    });

    test('目标被同名文件占住 → createFailed', () async {
      final File blocker = File(p.join(tempDir.path, 'blocker'));
      blocker.writeAsStringSync('x');
      expect(await checkDownloadSaveRoot(p.join(blocker.path, 'sub')),
          DownloadSaveRootIssue.createFailed);
    });
  });
}

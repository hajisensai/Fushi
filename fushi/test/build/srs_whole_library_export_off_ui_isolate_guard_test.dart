// 整库读的导出 / 捐赠预览不许在 UI isolate 上跑（反馈 wo-JxHl6hI：3.4.0 安卓牌组页 ANR）。
//
// 这几个函数要把全库笔记的修改记录、全部卡的血统与日志读回调用方 isolate 逐行解码（实测 9.4 万条修改记录 /
// 117 MB），Android / iOS 上 UI isolate 就跑在平台主线程，直接卡到 ANR。它们各有一个 `…InBackground` 版本
// （srs_store_background.dart `srsRunWithStoreInBackground`：一次性后台 isolate 按句柄号重开只读副本），
// app 代码（fushi/lib 与 packages/*/lib）一律走后台版；同步版只留给定义它们的 apkg 目录自己（后台版的后台一半
// 就是调同步版）与测试。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 只许在后台 isolate 里调的整库读函数 → 产品代码该用的后台版。
const Map<String, String> _kBackgroundOnly = <String, String>{
  'previewSrsDonation': 'previewSrsDonationInBackground',
  'exportSrsDonationFile': 'exportSrsDonationFileInBackground',
  'exportAnkiPackageFile': 'exportAnkiPackageFileInBackground',
  'exportAnkiPackage': 'exportAnkiPackageFileInBackground',
};

/// 定义这些函数的目录（后台版的后台一半在这里调同步版），不扫。
const String _kDefiningDir = 'packages/fushi_engine/lib/srs/apkg/';

/// 仓库根（测试在 fushi/ 下跑）。
final Directory _repo = Directory.current.parent;

String _rel(File f) =>
    p.relative(f.path, from: _repo.path).replaceAll(r'\', '/');

void main() {
  test('app 代码不在调用方 isolate 上跑整库读的导出 / 捐赠预览', () {
    final List<Directory> roots = <Directory>[
      Directory(p.join(_repo.path, 'fushi', 'lib')),
      for (final FileSystemEntity e in Directory(
        p.join(_repo.path, 'packages'),
      ).listSync())
        if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
          Directory(p.join(e.path, 'lib')),
    ];
    final Map<String, RegExp> calls = <String, RegExp>{
      for (final String name in _kBackgroundOnly.keys)
        name: RegExp('\\b$name\\s*\\('),
    };
    final List<String> offenders = <String>[];
    bool sawPreviewInBackground = false;
    for (final Directory root in roots) {
      for (final File f
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart'))) {
        final String rel = _rel(f);
        final String src = maskComments(f.readAsStringSync());
        if (src.contains('previewSrsDonationInBackground(')) {
          sawPreviewInBackground = true;
        }
        if (rel.startsWith(_kDefiningDir)) continue;
        for (final MapEntry<String, RegExp> c in calls.entries) {
          if (c.value.hasMatch(src)) {
            offenders.add('$rel: ${c.key} → 改用 ${_kBackgroundOnly[c.key]}');
          }
        }
      }
    }
    expect(
      sawPreviewInBackground,
      isTrue,
      reason: '捐赠页应经 previewSrsDonationInBackground 预览（守卫扫描范围失效？）',
    );
    expect(
      offenders,
      isEmpty,
      reason: '这些文件在调用方 isolate 上整库读（安卓 / iOS 上就是平台主线程，ANR）',
    );
  });
}

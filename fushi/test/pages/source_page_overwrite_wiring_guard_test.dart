// BUG-4933：查词弹窗点 ✓ 选「覆盖这张」走 [BaseSourcePageState.onUpdateFromPopup]，
// 基类默认是空实现（不写卡、不报错）。漫画 / PDF / 音乐歌词页都覆写了制卡
// `onMineFromPopup`，却没覆写覆写入口，于是「覆盖」静默无效。
//
// 本守卫按目录枚举 lib/ 下所有 `extends BaseSourcePageState<` 的宿主（连同它的
// `part` 文件）：只要宿主自己实现了制卡，就必须同时实现覆写，并且覆写真的落到
// `updateMinedNote`——新加的宿主漏接时这里先红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 宿主主文件 + 它 `part` 进来的文件，掩掉注释后折叠空白。
String _hostCorpus(File host) {
  final String source = host.readAsStringSync();
  final StringBuffer corpus = StringBuffer(compactCode(source));
  final RegExp partRe = RegExp(
    r'''^part\s+['"]([^'"]+)['"]\s*;''',
    multiLine: true,
  );
  for (final RegExpMatch m in partRe.allMatches(source)) {
    final File part = File(p.join(host.parent.path, m.group(1)!));
    corpus.write(compactCode(part.readAsStringSync()));
  }
  return corpus.toString();
}

void main() {
  test(
    'every source page that mines from the popup also overwrites for real',
    () {
      final List<File> hosts = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .where(
            (File f) =>
                f.readAsStringSync().contains('extends BaseSourcePageState<'),
          )
          .toList();
      // 防目录枚举失效假绿：已知至少有 EPUB / 漫画 / PDF / 音乐歌词四个宿主。
      expect(hosts.length, greaterThanOrEqualTo(4));

      const String mineOverride =
          '@overrideFuture<MinePopupResult>onMineFromPopup(';
      const String updateOverride =
          '@overrideFuture<MinePopupResult>onUpdateFromPopup(';
      final List<String> offenders = <String>[];
      int miningHosts = 0;
      for (final File host in hosts) {
        final String corpus = _hostCorpus(host);
        if (!corpus.contains(mineOverride)) continue;
        miningHosts++;
        if (!corpus.contains(updateOverride) ||
            !corpus.contains('repo.updateMinedNote(')) {
          offenders.add(host.path);
        }
      }
      expect(miningHosts, greaterThanOrEqualTo(4));
      expect(
        offenders,
        isEmpty,
        reason:
            '这些宿主实现了 onMineFromPopup，却没把 onUpdateFromPopup 接到 '
            'repo.updateMinedNote：点 ✓「覆盖这张」会落到基类空实现，静默不写卡',
      );
    },
  );
}

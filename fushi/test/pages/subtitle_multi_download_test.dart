import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';
import 'package:path/path.dart' as p;

/// 多选下载字幕时最容易悄悄丢东西的一环：不同 provider、不同版本组常常给出
/// 一模一样的文件名，裸写就是后一条把前一条盖掉——用户以为下了 5 条，盘上只剩
/// 1 条，而且被盖掉的那几条永远不会有人发现。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_subtitle_dest_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('目录里没有同名文件时原样落盘', () {
    final String dest = uniqueSubtitleDestination(dir.path, 'Show - 01.srt');
    expect(p.basename(dest), 'Show - 01.srt');
    expect(p.dirname(dest), dir.path);
  });

  test('同名已存在时加序号，不覆盖已有文件', () {
    File(p.join(dir.path, 'Show - 01.srt')).writeAsStringSync('first');
    final String dest = uniqueSubtitleDestination(dir.path, 'Show - 01.srt');
    expect(p.basename(dest), 'Show - 01 (2).srt');
    expect(
      File(p.join(dir.path, 'Show - 01.srt')).readAsStringSync(),
      'first',
      reason: '已有的那条必须原封不动',
    );
  });

  test('连续多条同名依次让位，一条都不丢', () {
    final List<String> written = <String>[];
    for (int i = 0; i < 4; i++) {
      final String dest = uniqueSubtitleDestination(dir.path, 'Same.srt');
      File(dest).writeAsStringSync('body-$i');
      written.add(dest);
    }
    expect(written.toSet(), hasLength(4), reason: '四条各占一个路径');
    expect(
      written.map((String f) => p.basename(f)).toList(),
      <String>['Same.srt', 'Same (2).srt', 'Same (3).srt', 'Same (4).srt'],
    );
    for (int i = 0; i < 4; i++) {
      expect(File(written[i]).readAsStringSync(), 'body-$i');
    }
  });

  test('保留扩展名，序号加在主干名后面', () {
    File(p.join(dir.path, 'a.ass')).writeAsStringSync('x');
    expect(
      p.basename(uniqueSubtitleDestination(dir.path, 'a.ass')),
      'a (2).ass',
    );
  });

  test('无扩展名的文件也能消歧', () {
    File(p.join(dir.path, 'noext')).writeAsStringSync('x');
    expect(
      p.basename(uniqueSubtitleDestination(dir.path, 'noext')),
      'noext (2)',
    );
  });
}

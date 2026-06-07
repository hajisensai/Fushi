import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 守卫：底栏高度必须经 appUiScale 缩放、且两条底栏都过 ReaderChromeScaler。
/// 防止未来有人把底栏高度写回硬编码常量或漏掉缩放器，导致界面大小不再吃到底栏、
/// 或视觉高度与 WebView 预留高度错位。
void main() {
  final File reader =
      File('lib/src/pages/implementations/reader_hibiki_page.dart');

  test('reader source file exists', () {
    expect(reader.existsSync(), isTrue, reason: '从 hibiki/ 目录跑 flutter test');
  });

  test('_readerChromeHeight is a scaled getter, not a const 56', () {
    final String src = reader.readAsStringSync();
    expect(
        src.contains('static const double _readerChromeHeight = 56'), isFalse,
        reason: '底栏高度必须随 appUiScale 缩放，不能写死 56');
    expect(
        src.contains('ReaderChromeScaler.scaledHeight(_readerChromeBaseHeight'),
        isTrue,
        reason:
            '_readerChromeHeight getter 必须走 ReaderChromeScaler.scaledHeight');
  });

  test('both bottom bars wrap content in ReaderChromeScaler', () {
    final String src = reader.readAsStringSync();
    final int count = 'ReaderChromeScaler('.allMatches(src).length;
    expect(count, greaterThanOrEqualTo(2),
        reason: '设置条 + 有声书播放条都必须套 ReaderChromeScaler');
  });
}

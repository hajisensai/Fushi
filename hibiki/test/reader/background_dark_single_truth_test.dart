import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';

/// G14：阅读器背景「深/浅」判定单一真相。
///
/// 修复前同一个阅读器背景色有两套判定：Dart（原生滚动条 light/dark 桶）用
/// Rec.601 luma、阈值 0.5；收藏高亮注入 JS（HighlightBridge `_luminance`）用
/// Rec.709 系数（且直接作用于 gamma 编码值）、阈值 0.4——深蓝灰一类背景会出现
/// 「滚动条按深色、渐变高亮透明度按浅色」的分叉。
///
/// 修法（路线 A）：Dart 侧 [ReaderContentStyles.isDarkBackground] 是唯一公式，
/// `HighlightBridge.applyHighlights` 用它算好 bool 经既有 evaluateJavascript
/// 注入 `window.__hibikiHighlightBgDark`；JS 侧公式删除。本文件：
/// ① 冻结 Dart 公式行为（含一个两套旧公式判定相反的深蓝灰用例）；
/// ② 源码守卫：JS 不得再出现亮度公式，Dart 侧必须经单一真相接线。
void main() {
  group('ReaderContentStyles.isDarkBackground（Rec.601/0.5 单一真相）', () {
    test('内置深色主题背景判深', () {
      expect(ReaderContentStyles.isDarkBackground('#121212'), isTrue);
      expect(ReaderContentStyles.isDarkBackground('#23272a'), isTrue);
      expect(ReaderContentStyles.isDarkBackground('#000'), isTrue);
    });

    test('内置浅色主题背景判浅', () {
      expect(ReaderContentStyles.isDarkBackground('#fff'), isFalse);
      expect(ReaderContentStyles.isDarkBackground('#f7f6eb'), isFalse); // ecru
      expect(ReaderContentStyles.isDarkBackground('#dfecf4'), isFalse); // water
      expect(ReaderContentStyles.isDarkBackground('#c7edcc'), isFalse); // 护眼
    });

    test('深蓝灰 #5a6b7c：旧 JS Rec.709/0.4 判浅、旧 Dart Rec.601/0.5 判深——统一后判深', () {
      // Rec.601 luma = (0.299*90 + 0.587*107 + 0.114*124)/255 ≈ 0.407 < 0.5。
      // 旧 JS：0.2126*r' + 0.7152*g' + 0.0722*b' ≈ 0.410 ≥ 0.4 → 判浅（分叉源）。
      expect(ReaderContentStyles.isDarkBackground('#5a6b7c'), isTrue);
    });

    test('解析不了的输入回退浅色（null / 命名色 / rgba()）', () {
      expect(ReaderContentStyles.isDarkBackground(null), isFalse);
      expect(ReaderContentStyles.isDarkBackground('black'), isFalse);
      expect(ReaderContentStyles.isDarkBackground('rgba(0,0,0,1)'), isFalse);
    });

    test('#rgb 短格式按位翻倍解析', () {
      expect(ReaderContentStyles.isDarkBackground('#234'), isTrue);
      expect(ReaderContentStyles.isDarkBackground('#eee'), isFalse);
    });
  });

  group('源码守卫：亮度公式只活在 Dart 一处', () {
    final String bridgeSrc = File(
      'lib/src/media/audiobook/highlight_bridge.dart',
    ).readAsStringSync();

    test('HighlightBridge JS 不得再持有亮度公式（Rec.709 系数 / _luminance）', () {
      expect(bridgeSrc.contains('0.2126'), isFalse,
          reason: 'JS 侧第二套亮度公式（Rec.709）必须删除，防再度分叉');
      expect(bridgeSrc.contains('_luminance'), isFalse,
          reason: 'JS 亮度函数必须删除，深浅只从 Dart 注入');
    });

    test('深浅 bool 经既有 bridge 注入且来自单一真相', () {
      expect(bridgeSrc.contains('__hibikiHighlightBgDark'), isTrue,
          reason: 'JS 读 Dart 注入的 __hibikiHighlightBgDark');
      expect(
          bridgeSrc
              .contains('ReaderContentStyles.isDarkBackground(backgroundHex)'),
          isTrue,
          reason: 'applyHighlights 必须用滚动条同款单一真相计算深浅');
    });
  });
}

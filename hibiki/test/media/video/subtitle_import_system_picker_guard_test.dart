import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-669 / board 1360 守卫：安卓「导入选字幕文件」回退到系统文件选择器。
///
/// board 1112 为「安卓单文件视频导入不复制到 cache（避免 videoPath 悬空）」引入了
/// 真实路径文件浏览器 `pickRealFilePath`，并顺手把字幕/对齐选择器也改走它。字幕/对齐
/// 文件在导入时即被解析成 cues / 生成 EPUB / 跑 matcher **当场消费**，不以绝对路径长期
/// 引用，SAF 复制到 cache 的临时副本读完即弃——真实路径浏览器对字幕**无收益、只有回归
/// 代价**（触达不到 Downloads / 云盘 / 最近文件、用户不熟悉）。故三个导入字幕/对齐选择
/// 器回退到系统文件选择器 `pickSystemFilePath`。
///
/// 守卫两件事：
/// 1) 三个导入字幕/对齐选择器走 `pickSystemFilePath`，且不再走 `pickRealFilePath`。
/// 2) 视频本体 `_pickVideo` **仍**走 `pickRealFilePath`（它以绝对路径引用、不复制，SAF
///    cache 路径会悬空——这是 board 1112/TODO-949 的真实修复，不能连同字幕一起回退）。
void main() {
  group('BUG-669 subtitle import reverts to system file picker', () {
    test('video _pickSubtitle uses pickSystemFilePath, not pickRealFilePath',
        () {
      final String body = _methodBody(
        File('lib/src/media/video/video_import_dialog.dart').readAsStringSync(),
        'Future<void> _pickSubtitle()',
      );
      expect(body, isNotEmpty, reason: '找不到 video _pickSubtitle');
      expect(
        body.contains('pickSystemFilePath('),
        isTrue,
        reason: '视频外挂字幕导入必须走系统文件选择器（board 1360）',
      );
      expect(
        body.contains('pickRealFilePath('),
        isFalse,
        reason: '不得再走真实路径浏览器（board 1360 回退）',
      );
    });

    test('book _pickSubtitle uses pickSystemFilePath, not pickRealFilePath',
        () {
      final String body = _methodBody(
        File('lib/src/media/audiobook/book_import_dialog.dart')
            .readAsStringSync(),
        'Future<void> _pickSubtitle()',
      );
      expect(body, isNotEmpty, reason: '找不到 book _pickSubtitle');
      expect(body.contains('pickSystemFilePath('), isTrue,
          reason: '书籍/有声书字幕导入必须走系统文件选择器（board 1360）');
      expect(body.contains('pickRealFilePath('), isFalse,
          reason: '不得再走真实路径浏览器（board 1360 回退）');
    });

    test(
        'audiobook _pickAlignment uses pickSystemFilePath, not pickRealFilePath',
        () {
      final String body = _methodBody(
        File('lib/src/media/audiobook/audiobook_import_dialog.dart')
            .readAsStringSync(),
        'Future<void> _pickAlignment()',
      );
      expect(body, isNotEmpty, reason: '找不到 audiobook _pickAlignment');
      expect(body.contains('pickSystemFilePath('), isTrue,
          reason: '有声书对齐字幕/SMIL/JSON 导入必须走系统文件选择器（board 1360）');
      expect(body.contains('pickRealFilePath('), isFalse,
          reason: '不得再走真实路径浏览器（board 1360 回退）');
    });

    test('video _pickVideo still keeps pickRealFilePath (must NOT revert)', () {
      final String body = _methodBody(
        File('lib/src/media/video/video_import_dialog.dart').readAsStringSync(),
        'Future<void> _pickVideo()',
      );
      expect(body, isNotEmpty, reason: '找不到 video _pickVideo');
      expect(
        body.contains('pickRealFilePath('),
        isTrue,
        reason: '视频本体以绝对路径引用不复制，SAF cache 路径会悬空——必须保留真实路径'
            '浏览器（board 1112/TODO-949），不能连同字幕一起回退成系统选择器',
      );
    });

    test('pickSystemFilePath entry exists and routes to system file picker',
        () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      expect(
        src.contains('Future<String?> pickSystemFilePath('),
        isTrue,
        reason: '必须存在系统文件选择器入口 pickSystemFilePath',
      );
      final String body =
          _methodBody(src, 'Future<String?> pickSystemFilePath(');
      expect(
        body.contains('_fallbackPickFile('),
        isTrue,
        reason: 'pickSystemFilePath 必须走系统文件选择器（复用 _fallbackPickFile），'
            '不弹自建真实路径浏览器',
      );
    });
  });
}

/// 取从 [signature] 起到下一个顶层 `Future<` / `class ` 声明前的方法体切片。
String _methodBody(String src, String signature) {
  final int idx = src.indexOf(signature);
  if (idx < 0) return '';
  final int nextFuture = src.indexOf('Future<', idx + signature.length);
  final int nextClass = src.indexOf('\nclass ', idx + signature.length);
  int end = src.length;
  for (final int cand in <int>[nextFuture, nextClass]) {
    if (cand >= 0 && cand < end) end = cand;
  }
  return src.substring(idx, end);
}

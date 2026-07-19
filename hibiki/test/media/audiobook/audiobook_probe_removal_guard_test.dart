import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-914：移除有声书按句同步/高亮热路径的发布版诊断噪声后，锁住这两处
/// 打点不再回归。测试从 `hibiki/` 工作目录运行：
/// - 桥接文件在本包内（`lib/src/media/audiobook/audiobook_bridge.dart`），
///   曾在播放期逐 cue 打 `[sasayaki-hl]`（highlight raw / applySasayakiCues
///   EMPTY payload）。
/// - 控制器在 `hibiki_audio` 包（`../packages/hibiki_audio/lib/src/audiobook/
///   audiobook_controller.dart`），曾在 `_maybeEmitCrossChapter` 按句同步热
///   路径打 `[hibiki-crossChapter]`（blocked / cueSec）。
void main() {
  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue,
        reason: 'expected source at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('audiobook bridge no longer emits [sasayaki-hl] playback probes', () {
    final String source =
        readSource('lib/src/media/audiobook/audiobook_bridge.dart');
    expect(source, isNot(contains('[sasayaki-hl]')),
        reason: 'BUG-914: 播放期逐句高亮的 [sasayaki-hl] 诊断打点必须移除，'
            '避免发布版热路径噪声');
  });

  test('audiobook controller no longer emits [hibiki-crossChapter] probes', () {
    final String source = readSource(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart');
    expect(source, isNot(contains('[hibiki-crossChapter]')),
        reason: 'BUG-914: _maybeEmitCrossChapter 按句同步热路径的 '
            '[hibiki-crossChapter] print 必须移除');
  });
}

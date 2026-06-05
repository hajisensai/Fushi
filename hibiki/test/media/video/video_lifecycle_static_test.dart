import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频退出 flush 的「时序不变式」——无法用纯单测覆盖（需真实 libmpv
/// player），故在源码层钉死结构：
///
/// **退出 flush（问题 1）**：`VideoPlayerController.dispose` 必须**先**强制保存
/// 当前位置（绕过整秒节流）**再**释放 player，否则退出瞬间同一整秒内的最后几百
/// 毫秒进度被节流吞掉 →「退出再进没回到上次位置」。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  group('VideoPlayerController exit flush (问题 1)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('dispose force-saves the position before disposing the player', () {
      final RegExpMatch? body = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 dispose 方法体');
      final String b = body!.group(1)!;
      final int saveAt = b.indexOf('_forceSavePositionSync()');
      final int playerDisposeAt = b.indexOf('_player?.dispose()');
      expect(saveAt, greaterThanOrEqualTo(0),
          reason: 'dispose 必须强制保存当前位置（退出 flush）');
      expect(playerDisposeAt, greaterThan(saveAt),
          reason: '强制保存必须在释放 player 之前（之后 positionMs 读不到）');
    });

    test('a public flushPosition() awaits the persistence write', () {
      final RegExpMatch? body = RegExp(
        r'Future<void> flushPosition\(\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 flushPosition 方法体');
      expect(body!.group(1), contains('await onPositionWrite?.call('),
          reason: 'flushPosition 必须 await 到真正落库（durability）');
    });
  });
}

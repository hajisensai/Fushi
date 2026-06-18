import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoHibikiPage chapter first-load guards (TODO-521)', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    test('controller and _hasChapters are aligned in the same setState', () {
      final int applyLoad = src.indexOf('Future<void> _applyLoad({');
      expect(applyLoad, greaterThanOrEqualTo(0));
      final int syncCall = src.indexOf(
          '_syncControllerChapterAvailability(controller);', applyLoad);
      expect(syncCall, greaterThan(applyLoad));
      final String body = src.substring(applyLoad, syncCall);

      expect(body, contains('_controller = controller;'));
      expect(body, contains('_hasChapters = controller.chapters.isNotEmpty;'),
          reason: '首次章节通知早到时，页面仍要在 controller 赋值同帧对齐章节入口');
    });

    test('chapter listener captures the notifying controller identity', () {
      expect(src, contains('void listener() =>'));
      expect(src, contains('_onControllerChaptersChanged(controller);'));
      expect(src, contains('if (_controller != controller) return;'),
          reason: 'listener 早到/旧 controller 迟到都不能读 null 或旧 controller');
      expect(src, contains('_detachControllerChapterListener();'),
          reason: '换 controller / dispose 必须移除闭包 listener');
    });

    test('integration hooks expose first-load chapter evidence only', () {
      expect(src, contains('int get debugChapterCount;'));
      expect(src, contains('int? get debugDurationMs;'));
      expect(src, contains('void debugShowChapterPanel();'));
    });
  });
}

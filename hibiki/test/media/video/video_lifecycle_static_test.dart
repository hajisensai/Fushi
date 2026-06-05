import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频三问题的两条「时序不变式」——它们无法用纯单测覆盖（需真实
/// libmpv player / 完整 AppModel+Riverpod 书架页），故在源码层钉死结构：
///
/// 1. **退出 flush（问题 1）**：`VideoPlayerController.dispose` 必须**先**强制保存
///    当前位置（绕过整秒节流）**再**释放 player，否则退出瞬间同一整秒内的最后
///    几百毫秒进度被节流吞掉 →「退出再进没回到上次位置」。
/// 2. **删除不闪回（问题 3）**：书架 `_deleteVideoBook` 必须**先**乐观地从内存
///    列表 `_videoBooks` 同步移除该项 + `setState`，**再** `await` 删 DB；若顺序
///    反了（先删 DB 再 future 刷新），格子会渲染旧列表直到 future 完成 → 卡片
///    闪回。
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

  group('shelf video delete: optimistic removal (问题 3)', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_history_page.dart');

    test('_deleteVideoBook removes from _videoBooks before awaiting the DB',
        () {
      final RegExpMatch? body = RegExp(
        r'Future<void> _deleteVideoBook\([^)]*\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 _deleteVideoBook 方法体');
      final String b = body!.group(1)!;
      final int optimisticAt = b.indexOf('_videoBooks = _videoBooks');
      final int dbDeleteAt = b.indexOf('await _videoRepo.delete(');
      expect(optimisticAt, greaterThanOrEqualTo(0), reason: '必须先乐观地从内存列表移除该项');
      expect(b.indexOf('setState'), lessThan(dbDeleteAt),
          reason: 'setState 必须在 await 删 DB 之前（立即移除卡片，不回弹）');
      expect(optimisticAt, lessThan(dbDeleteAt),
          reason: '乐观移除必须先于异步删 DB，否则卡片闪回');
    });

    test('video delete does NOT re-run the async _loadVideoBooks future', () {
      // 删除走乐观移除，绝不能调 _refreshVideoBooks()（它重建
      // _videoBooksFuture → 重跑 _loadVideoBooks → 渲染旧 _videoBooks 直到完成
      // → 正是闪回根因）。
      final RegExpMatch? body = RegExp(
        r'Future<void> _deleteVideoBook\([^)]*\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body!.group(1), isNot(contains('_refreshVideoBooks(')),
          reason: '删除不得重跑 _loadVideoBooks（future 刷新会让被删卡片闪回）');
    });
  });
}

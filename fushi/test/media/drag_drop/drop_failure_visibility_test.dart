import 'dart:io' show FileSystemException;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/drag_drop/image_archive_probe.dart';

/// 拖放失败不再静默消失的守卫。
///
/// 背景：全部文件拖入入口（书架 / 视频库 / 词典页 / 游戏库 / 播放页 + 四个导入
/// 对话框）都把自己的路由函数挂在 desktop_drop 的回调上。回调过去声明成 `void` 且
/// 没有任何 try/catch，处理器一抛异常就直接漂进 zone——用户看到的只有「拖了没
/// 反应」，而「拖了没反应」恰好又长得像「这类文件不支持」，他会得出完全错误的结论。
///
/// 断言分两层，缺一不可：
///  ① 异常不许从 [FushiFileDropTarget.runDrop] 漏出去（漏出去 = 整次拖放消失）；
///  ② 失败**必须**被上报（只断①的话，把 catch 体写空同样能过——那就是把「静默
///     消失」换成「静默吞掉」，用户处境一模一样）。
void main() {
  FushiFileDropTarget targetWith(
    FileDropCallback onDrop,
    List<Object> reported,
  ) =>
      FushiFileDropTarget(
        onDrop: onDrop,
        onDropFailure: (Object error, StackTrace _) => reported.add(error),
        child: const SizedBox.shrink(),
      );

  test('同步处理器抛出：不外泄且被上报', () async {
    final List<Object> reported = <Object>[];
    final FushiFileDropTarget target = targetWith(
      (List<String> paths, Offset position) => throw StateError('boom-sync'),
      reported,
    );

    await target.runDrop(<String>['/a.epub'], Offset.zero);

    expect(reported, hasLength(1));
    expect(reported.single, isA<StateError>());
  });

  test('异步处理器抛出：同样不外泄且被上报', () async {
    // 这条是把 [FileDropCallback] 从 `void` 改成 `FutureOr<void>` 的理由：处理器
    // 变成 `async` 之后，只包同步栈的 try/catch 接不住它抛的异常。把返回类型改回
    // `void`（或把 runDrop 里的 await 去掉）这条就红。
    final List<Object> reported = <Object>[];
    final FushiFileDropTarget target = targetWith(
      (List<String> paths, Offset position) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('boom-async');
      },
      reported,
    );

    await target.runDrop(<String>['/a.zip'], Offset.zero);

    expect(reported, hasLength(1));
    expect(reported.single, isA<StateError>());
  });

  test('处理器正常返回时不上报任何失败', () async {
    final List<Object> reported = <Object>[];
    final List<String> seen = <String>[];
    final FushiFileDropTarget target = targetWith(
      (List<String> paths, Offset position) async => seen.addAll(paths),
      reported,
    );

    await target.runDrop(<String>['/a.epub'], Offset.zero);

    expect(seen, <String>['/a.epub']);
    expect(reported, isEmpty);
  });

  group('probeDroppedImageArchives', () {
    test('只对扩展名二义的 .zip 开包，其余一次都不问', () async {
      final List<String> probed = <String>[];
      final Map<String, bool> result = await probeDroppedImageArchives(
        <String>['/a.zip', '/b.epub', '/c.mkv', '/d', '/e.ZIP'],
        probe: (String path) async {
          probed.add(path);
          return true;
        },
      );

      expect(probed, <String>['/a.zip', '/e.ZIP'],
          reason: '.epub / 视频 / 无扩展名都不该白开一次包');
      expect(result, <String, bool>{'/a.zip': true, '/e.ZIP': true});
    });

    test('同一路径重复拖入只开一次包', () async {
      int calls = 0;
      await probeDroppedImageArchives(
        <String>['/a.zip', '/a.zip'],
        probe: (String path) async {
          calls += 1;
          return false;
        },
      );

      expect(calls, 1);
    });

    test('开包失败只是「不是图片包」，不炸掉整次拖放', () async {
      final Map<String, bool> result = await probeDroppedImageArchives(
        <String>['/broken.zip'],
        probe: (String path) async => throw const FileSystemException('nope'),
      );

      expect(result, <String, bool>{'/broken.zip': false},
          reason: '损坏包应落回按扩展名的常规分类（.zip → 词典包），而不是抛出去');
    });
  });
}

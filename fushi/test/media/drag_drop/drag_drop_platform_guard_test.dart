import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../pages/reader_history_source_corpus.dart';
import '../../helpers/scan_scale.dart';

void main() {
  final File wrapper = File(
    'lib/src/media/drag_drop/fushi_file_drop_target.dart',
  );

  test('desktop_drop is only imported inside the platform-gated wrapper', () {
    final Directory libDir = Directory('lib');
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity e in libDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      scanned++;
      if (e.path
          .replaceAll('\\', '/')
          .endsWith('src/media/drag_drop/fushi_file_drop_target.dart')) {
        continue;
      }
      final String src = e.readAsStringSync();
      if (src.contains('package:desktop_drop/')) {
        offenders.add(e.path);
      }
    }
    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
    expect(offenders, isEmpty,
        reason: 'desktop_drop should only be imported by FushiFileDropTarget');
  });

  test('wrapper forwards globalPosition, gates route state, and logs', () {
    final String src = wrapper.readAsStringSync();

    expect(src.contains('DropDoneDetails detail'), isTrue);
    // 派发多了一跳 [FushiFileDropTarget.runDrop]（异常收口在那里），坐标语义不变：
    // 进 runDrop 的仍是 detail.globalPosition，runDrop 原样交给 onDrop。两段都断，
    // 中间那一跳把坐标换成 local 也会当场红。
    expect(src.contains('runDrop(paths, detail.globalPosition)'), isTrue,
        reason: 'business handlers hit-test cards in Flutter global coords');
    expect(src.contains('await onDrop(paths, globalPosition)'), isTrue,
        reason: '必须 await：处理器是 FutureOr，不 await 则 async 抛出漏过 catch');
    expect(src.contains('detail.localPosition'), isTrue,
        reason: 'localPosition should still be logged for diagnostics');
    expect(src.contains('onDrop(paths, detail.localPosition)'), isFalse,
        reason:
            'do not leak local coords to callers that already expect global');
    expect(src.contains('enable: enabled'), isTrue,
        reason:
            'listener registration must not be lost if route visibility changes without a rebuild');
    expect(src.contains('ModalRoute.of(context)'), isTrue,
        reason: 'targets behind a pushed route must not consume OS drops');
    // 门已从四个匿名回调里的手抄副本收敛成一个具名函数（测试够得到、能被 widget
    // 测试真正驱动）：路由可见性 + 表面可见性都在这里判。
    expect(src.contains('bool dropSurfaceActive(BuildContext context)'), isTrue,
        reason: 'route visibility is checked when each OS drop event arrives');
    expect(src.contains('DropSurfaceScope.activeFor(context)'), isTrue,
        reason: '同一条路由里被 Offstage/IndexedStack 保活的隐藏子树也必须被挡住');
    expect(src.contains('onDragUpdated'), isTrue,
        reason: 'hover/update logs are needed to diagnose Windows drop paths');
    expect(src.contains('[fushi-drop]'), isTrue,
        reason: 'Windows drag/drop failures need visible diagnostic logs');
  });

  test('library drop handlers use globalPosition without converting again', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String shelf = readReaderHistorySource();

    String functionBody(String source, String start, String end) {
      final int startIndex = source.indexOf(start);
      expect(startIndex, greaterThanOrEqualTo(0), reason: 'missing $start');
      final int endIndex = source.indexOf(end, startIndex + start.length);
      expect(endIndex, greaterThan(startIndex), reason: 'missing $end');
      return source.substring(startIndex, endIndex);
    }

    final String videoDrop = functionBody(
      video,
      'void _handleVideoDrop(',
      'Future<void> _openVideoImportPrefilled(',
    );
    expect(videoDrop.contains('Offset globalPosition'), isTrue);
    expect(videoDrop.contains('_cardDropRegistry.hitTest(globalPosition)'),
        isTrue);
    expect(videoDrop.contains('localToGlobal('), isFalse,
        reason: 'DropDoneDetails.globalPosition must not be converted again');
    expect(videoDrop.contains('DropIntent.unsupportedSurface'), isTrue,
        reason: 'recognized files on the wrong surface need visible feedback');

    // 书架落点要先离线程判「这个 .zip 是不是图片包」，故签名是 Future<void>；
    // 同步解包留在 drop 栈上会把 UI 线程卡死（见 image_archive_probe.dart）。
    final String shelfDrop = functionBody(
      shelf,
      'Future<void> _handleShelfDrop(',
      'Future<void> _openBookImportPrefilled(',
    );
    expect(shelfDrop.contains('Offset globalPosition'), isTrue);
    expect(shelfDrop.contains('_cardDropRegistry.hitTest(globalPosition)'),
        isTrue);
    expect(shelfDrop.contains('localToGlobal('), isFalse,
        reason: 'DropDoneDetails.globalPosition must not be converted again');
    expect(shelfDrop.contains('DropIntent.unsupportedSurface'), isTrue,
        reason: 'recognized files on the wrong surface need visible feedback');
  });
}

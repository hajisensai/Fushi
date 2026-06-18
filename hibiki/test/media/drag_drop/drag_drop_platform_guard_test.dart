import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File wrapper = File(
    'lib/src/media/drag_drop/hibiki_file_drop_target.dart',
  );

  test('desktop_drop is only imported inside the platform-gated wrapper', () {
    final Directory libDir = Directory('lib');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in libDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path
          .replaceAll('\\', '/')
          .endsWith('src/media/drag_drop/hibiki_file_drop_target.dart')) {
        continue;
      }
      final String src = e.readAsStringSync();
      if (src.contains('package:desktop_drop/')) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'desktop_drop should only be imported by HibikiFileDropTarget');
  });

  test('wrapper forwards globalPosition, gates route state, and logs', () {
    final String src = wrapper.readAsStringSync();

    expect(src.contains('DropDoneDetails detail'), isTrue);
    expect(src.contains('onDrop(paths, detail.globalPosition)'), isTrue,
        reason: 'business handlers hit-test cards in Flutter global coords');
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
    expect(src.contains('bool _routeVisible(BuildContext context)'), isTrue,
        reason: 'route visibility is checked when each OS drop event arrives');
    expect(src.contains('onDragUpdated'), isTrue,
        reason: 'hover/update logs are needed to diagnose Windows drop paths');
    expect(src.contains('[hibiki-drop]'), isTrue,
        reason: 'Windows drag/drop failures need visible diagnostic logs');
  });

  test('library drop handlers use globalPosition without converting again', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String shelf = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();

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

    final String shelfDrop = functionBody(
      shelf,
      'void _handleShelfDrop(',
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

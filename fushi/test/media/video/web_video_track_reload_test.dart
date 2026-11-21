import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_session.dart';

import '../../helpers/source_guard.dart';

/// gap-webvideo-10：live 轨边看边长、每采到一句就同 key 整轨重投。当前显示的是另一条整轨时，
/// 那些重投不该把当前轨整份重灌进字幕 controller（[webVideoTrackUpdateNeedsReload]，内置网页
/// 播放器页 `_reselectTrack` 与原生播放器页网页档 `_reselectWebTrack` 共用）。
void main() {
  const String full = 'vid|ja';
  const String live = 'vid|live';

  test('当前是整轨、没选中的 live 轨长了一句：不重灌', () {
    expect(
      webVideoTrackUpdateNeedsReload(
        updatedKey: live,
        previousActiveKey: full,
        nextActiveKey: full,
      ),
      isFalse,
    );
  });

  test('更新的正是当前轨（当前就是 live 轨）：要灌，新句子才显示得出来', () {
    expect(
      webVideoTrackUpdateNeedsReload(
        updatedKey: live,
        previousActiveKey: live,
        nextActiveKey: live,
      ),
      isTrue,
    );
  });

  test('整轨到了、取代先到的 live 轨：选轨变了，要灌', () {
    expect(
      webVideoTrackUpdateNeedsReload(
        updatedKey: full,
        previousActiveKey: live,
        nextActiveKey: full,
      ),
      isTrue,
    );
  });

  test('第一条轨到了（之前没有当前轨）：要灌', () {
    expect(
      webVideoTrackUpdateNeedsReload(
        updatedKey: live,
        previousActiveKey: null,
        nextActiveKey: live,
      ),
      isTrue,
    );
  });

  test('别的语言整轨到了但选轨不变：不重灌', () {
    expect(
      webVideoTrackUpdateNeedsReload(
        updatedKey: 'vid|en',
        previousActiveKey: full,
        nextActiveKey: full,
      ),
      isFalse,
    );
  });

  test('两处宿主的「轨到了」都带上更新的 key，重选经共享选轨按判据决定灌不灌', () {
    for (final (String path, String onTrack, String reselect)
        in <(String, String, String)>[
          (
            'lib/src/pages/implementations/web_video_fushi_page.dart',
            'void _onTrack(',
            'void _reselectTrack(',
          ),
          (
            'lib/src/pages/implementations/video_fushi/web_source.part.dart',
            'void _onWebTrack(',
            'void _reselectWebTrack(',
          ),
        ]) {
      final String src = File(path).readAsStringSync();
      expect(
        compactCode(methodBody(src, onTrack)),
        contains('(updatedKey:track.key);'),
        reason: path,
      );
      final String body = compactCode(methodBody(src, reselect));
      final int gate = body.indexOf('if(!r.reload)return;');
      expect(body, contains('.reselect(updatedKey:updatedKey,'), reason: path);
      expect(gate, greaterThanOrEqualTo(0), reason: path);
      expect(body.indexOf('.setCues('), greaterThan(gate), reason: path);
    }
    final String sel = compactCode(
      methodBody(
        File(
          'lib/src/media/video/web_video_track_selection.dart',
        ).readAsStringSync(),
        'WebVideoTrackReselect reselect(',
      ),
    );
    expect(sel, contains('webVideoTrackUpdateNeedsReload('));
  });
}

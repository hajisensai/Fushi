import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_volume_pref.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../../helpers/source_guard.dart' show compactCode;
import '../../pages/video_fushi_page_source_corpus.dart';

/// cehHSgF04K：「视频自动连播会取消沉浸模式；音量设置没有跟随系列」。
///
/// 两个症状同一根：统一合集 Phase 3 之后本地换集 = pushReplacement 一个新的单集页，
/// 每集是独立 VideoBooks 行。
///  * 沉浸锁定是页面局部状态（`_immersiveLocked`），换集时没交接，新页恒从未锁定开始；
///  * 音量键 `video_volume_<bookUid>` 随之变成「每集一个」，连播到下一集读的是那集自己的
///    值（多半是默认 100）。
///
/// ① 音量键纯函数：合集里读写系列键、系列键缺省回退旧的本集键；② 新页构造口真的把
/// 沉浸锁定透传下去（真实 widget 构造，不靠字符串）；③ 接线守卫：换集交接当前锁定态、
/// initState 在订阅前播种、页面读写音量走系列键。
void main() {
  group('音量键（系列级）', () {
    test('合集里写系列键，单视频写本条目键（旧键名冻结不变）', () {
      expect(
        videoVolumeWriteKey(bookUid: 'ep2', collectionId: 7),
        'video_volume_collection_7',
      );
      expect(videoVolumeWriteKey(bookUid: 'solo'), 'video_volume_solo');
      expect(videoVolumePrefKey('solo'), 'video_volume_solo');
    });

    test('同一合集的不同集写同一个键（连播不再换音量）', () {
      expect(
        videoVolumeWriteKey(bookUid: 'ep1', collectionId: 7),
        videoVolumeWriteKey(bookUid: 'ep2', collectionId: 7),
      );
    });

    test('读取顺序：系列键优先，回退本集旧键', () {
      expect(videoVolumeReadKeys(bookUid: 'ep2', collectionId: 7), <String>[
        'video_volume_collection_7',
        'video_volume_ep2',
      ]);
      expect(videoVolumeReadKeys(bookUid: 'solo'), <String>[
        'video_volume_solo',
      ]);
    });
  });

  group('沉浸锁定随换集交接', () {
    test('neutralized 入口把 initialImmersiveLocked 透传给新页', () {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      VideoFushiPage pageOf(bool locked) {
        final FushiAppUiScaleNeutralizer w =
            VideoFushiPage.neutralized(
                  bookUid: 'ep2',
                  repo: repo,
                  playlistCollectionId: 7,
                  initialImmersiveLocked: locked,
                )
                as FushiAppUiScaleNeutralizer;
        return w.child as VideoFushiPage;
      }

      expect(pageOf(true).initialImmersiveLocked, isTrue);
      expect(pageOf(false).initialImmersiveLocked, isFalse);
      expect(
        VideoFushiPage(bookUid: 'x', repo: repo).initialImmersiveLocked,
        isFalse,
        reason: '首开默认不锁',
      );
    });

    test('本地换集把当前锁定态交给新页；initState 在订阅前播种', () {
      final String episode = File(
        'lib/src/pages/implementations/video_fushi/episode.part.dart',
      ).readAsStringSync();
      expect(
        compactCode(episode),
        contains(
          compactCode('initialImmersiveLocked: _immersiveLocked.value,'),
        ),
        reason: '手动换集与自动连播都走 _switchEpisode 的同一个新页构造',
      );
      final String page = compactCode(readVideoFushiSource());
      final int seed = page.indexOf(
        compactCode('_immersiveLocked.value = widget.initialImmersiveLocked;'),
      );
      final int listen = page.indexOf(
        compactCode(
          '_immersiveLocked.addListener(_applyControlsVisibilityFromMediaKit);',
        ),
      );
      expect(seed, greaterThanOrEqualTo(0));
      expect(listen, greaterThan(seed), reason: '首帧控制条可见性就按锁定态派生');
    });
  });

  test('页面音量读写走系列键', () {
    final String page = compactCode(readVideoFushiSource());
    expect(
      page,
      contains(
        compactCode(
          'String get _volumePrefKey => videoVolumeWriteKey( '
          'bookUid: _activeBookUid, '
          'collectionId: widget.playlistCollectionId,',
        ),
      ),
    );
    expect(
      page,
      contains(
        compactCode(
          'videoVolumeReadKeys( bookUid: _activeBookUid, '
          'collectionId: widget.playlistCollectionId,',
        ),
      ),
    );
  });
}

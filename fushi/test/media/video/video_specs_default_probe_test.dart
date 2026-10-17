import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';

import '../../helpers/fake_video_specs_probe.dart';

/// 钉住「测试套件默认不真起 ffprobe」这条根因修复。
///
/// `AppModel.videoSpecsService` 用 `VideoSpecsService(db)` 懒建、不传探测器；
/// 渲染真实视频文件的 widget 测试一旦拿到真探测器，就会起 ffprobe 子进程与
/// FakeAsync 的 20s 超时计时器赛跑，装了 ffmpeg 的环境里随机报 pending timer。
/// 套件级默认由 `test/flutter_test_config.dart` 装上；这里任何一条红了，说明那条
/// 装配被删了或构造函数不再读默认探测器。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('套件级默认探测器是不起进程的假探测器', () {
    expect(
      identical(videoSpecsDefaultProbe, fakeVideoSpecsProbe),
      isTrue,
      reason: 'flutter_test_config.dart 必须调用 installFakeVideoSpecsProbe()',
    );
    expect(identical(videoSpecsDefaultProbe, probeVideoFacts), isFalse);
  });

  test('未传 probe 的服务（AppModel 懒建的那种）用默认探测器', () {
    final VideoSpecsService service = VideoSpecsService(db);
    addTearDown(service.dispose);
    expect(identical(service.probe, fakeVideoSpecsProbe), isTrue);
  });

  test('显式传入的 probe 优先于默认', () {
    Future<VideoProbeFacts> explicit(String _) async =>
        VideoProbeFacts.unavailable;
    final VideoSpecsService service = VideoSpecsService(db, probe: explicit);
    addTearDown(service.dispose);
    expect(identical(service.probe, explicit), isTrue);
  });
}

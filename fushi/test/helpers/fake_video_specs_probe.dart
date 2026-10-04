import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';

/// 不起进程的规格探测器：恒报「探完了、这文件没有规格」。
///
/// 返回 [VideoProbeFacts.empty] 而不是 `unavailable`：后者会让服务进 90s 重试冷却，
/// 测试里没有任何意义，还会多挂一层状态。
Future<VideoProbeFacts> fakeVideoSpecsProbe(String path) async =>
    VideoProbeFacts.empty;

/// 套件级默认：让所有**未显式传 `probe:`** 的 [VideoSpecsService]（主要是
/// `AppModel.videoSpecsService` 懒建的那一个）不真起 ffprobe。
///
/// 根因：视频库卡片的清晰度角标经 `videoSpecsProvider` 拿到真实服务，渲染真实视频
/// 文件时会起 ffprobe 子进程，与 FakeAsync 的 20s 超时计时器赛跑；装了 ffmpeg 的
/// 环境（本机 / ubuntu CI）里测试结束时计时器还挂着就随机报 pending timer。
///
/// 由 `test/flutter_test_config.dart` 调用。测规格探测本身的测试一律显式传 `probe:`
/// （见 `test/media/video/video_specs_service_test.dart`），不受这条默认影响；
/// 真要测默认探测器的测试可在自己的 `setUp` 里把 [videoSpecsDefaultProbe] 设回
/// `probeVideoFacts`、`tearDown` 再调本函数。
void installFakeVideoSpecsProbe() {
  videoSpecsDefaultProbe = fakeVideoSpecsProbe;
}

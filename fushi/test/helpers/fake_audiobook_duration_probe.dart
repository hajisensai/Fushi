import 'package:fushi_audio/fushi_audio.dart';

/// 套件级默认：有声书音频时长探测（[AudiobookStorage.audioDurationProbeMs]）在测试里
/// 一律返回 0（= 探不出，cue 不按文件切）。
///
/// 根因：`installEngineHostBindings()` 装的是 just_audio 的平台探测，每个文件构造
/// 一个 `AudioPlayer`；没有 Flutter binding 的纯逻辑测试里，它的构造会在一个没人
/// await 的 future 里抛断言（audio_session 设 method channel），以未捕获异步错误
/// 打红恰好在跑的用例并让它超时。多文件 + 单时间轴字幕的导入 / 重新导入路径都会
/// 探时长（BUG-4248），这类测试是开放集合，所以在套件级装一次。
///
/// 由 `test/flutter_test_config.dart` 调用；要测 cue 归文件的测试在自己的 `setUp`
/// 里装按文件给时长的假探测。
void installFakeAudiobookDurationProbe() {
  AudiobookStorage.audioDurationProbeMs = (String path) async => 0;
}

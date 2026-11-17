import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_pipeline_gate.dart';

void main() {
  bool gate({
    String? videoPath = r'D:\discs\Show\BDMV\PLAYLIST\00001.mpls',
    bool isRemote = false,
    bool asrSupported = true,
    bool discSession = false,
    bool discExtractionAvailable = false,
  }) => canRunLocalVideoSubtitlePipeline(
    videoPath: videoPath,
    isRemote: isRemote,
    asrSupported: asrSupported,
    discSession: discSession,
    discExtractionAvailable: discExtractionAvailable,
  );

  test('本机视频：有路径、本平台有语音识别就能跑', () {
    expect(gate(videoPath: r'D:\video\ep01.mkv'), isTrue);
    expect(gate(videoPath: null), isFalse);
    expect(gate(videoPath: ''), isFalse);
    expect(gate(asrSupported: false), isFalse);
    expect(gate(isRemote: true), isFalse, reason: '远端走 host 管线，不在本机判');
  });

  test('蓝光原盘会话：按原盘 VM 给的可抽取性判，不按「是不是蓝光」判', () {
    expect(gate(discSession: true, discExtractionAvailable: true), isTrue);
    // AACS 没密钥 / 多角度 / 片段缺失 / 盘菜单在前台：读不到音轨。
    expect(gate(discSession: true, discExtractionAvailable: false), isFalse);
    expect(
      gate(
        discSession: true,
        discExtractionAvailable: true,
        asrSupported: false,
      ),
      isFalse,
    );
  });
}

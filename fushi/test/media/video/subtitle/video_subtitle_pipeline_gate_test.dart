import 'package:test/test.dart';
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

  test('管线读媒体的路径：原盘会话读原盘 VM 的抽取路径（多角度带角度），其余读当前这一集', () {
    const String title = r'D:\discs\Show\BDMV\PLAYLIST\00001.mpls';
    const String angle = r'D:\discs\Show\BDMV\PLAYLIST\00001.a2.mpls';
    expect(
      localVideoSubtitlePipelineMediaPath(
        currentVideoPath: title,
        discSession: true,
        discExtractionPath: angle,
      ),
      angle,
    );
    // 当前 title 抽不了（加密没密钥 / 角度还没报上来）：没有可读路径。
    expect(
      localVideoSubtitlePipelineMediaPath(
        currentVideoPath: title,
        discSession: true,
        discExtractionPath: null,
      ),
      isNull,
    );
    expect(
      localVideoSubtitlePipelineMediaPath(
        currentVideoPath: r'D:\video\ep01.mkv',
        discSession: false,
        discExtractionPath: null,
      ),
      r'D:\video\ep01.mkv',
    );
  });

  test('DVD 原盘会话：title 可抽取（dvdvideo 按 title 读）就走管线，读的是当前 title', () {
    const String title = r'D:\discs\Show\VIDEO_TS\TITLE_02.dvdtitle';
    expect(
      localVideoSubtitlePipelineMediaPath(
        currentVideoPath: title,
        discSession: true,
        discExtractionPath: title,
      ),
      title,
    );
    expect(
      gate(videoPath: title, discSession: true, discExtractionAvailable: true),
      isTrue,
    );
  });
}

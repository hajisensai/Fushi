import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:test/test.dart';

/// ffmpeg 的 `-http_proxy` 是 app 已做完的出站裁决；继承来的 NO_PROXY 不得再让
/// ffmpeg 绕开它（NO_PROXY 列了 127.0.0.1 时中继形式的明文地址被直连到 https 原点，
/// 制卡抽取 `Error opening input files: End of file`）。
void main() {
  test('带 -http_proxy 时清掉继承的 NO_PROXY / no_proxy', () {
    expect(
      ffmpegChildEnvironment(<String>[
        '-http_proxy',
        'http://127.0.0.1:1234',
        '-i',
        'http://127.0.0.1:5678/v.mp4',
      ]),
      <String, String>{'NO_PROXY': '', 'no_proxy': ''},
    );
  });

  test('不带 -http_proxy（本地输入 / 直连裁决）时原样继承环境', () {
    expect(
      ffmpegChildEnvironment(<String>['-i', 'C:/v.mp4', 'out.aac']),
      isNull,
    );
  });
}

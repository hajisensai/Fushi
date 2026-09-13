import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 配置文件的 ffmpeg / ffprobe 路径必须**真正生效**（装进引擎显式覆盖），而不是只
/// 做展示。
void main() {
  tearDown(() {
    ffmpegPathOverride = null;
    ffprobePathOverride = null;
  });

  test('validateFfmpeg：路径不存在报第一条，存在返回 null，未配置不校验', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('fushi_ffmpeg_');
    addTearDown(() => tmp.delete(recursive: true));
    final File fake = File(p.join(tmp.path, 'ffmpeg'))..writeAsStringSync('');
    final ServerConfig base = ServerConfig.defaults(dataDir: tmp.path);

    expect(await validateFfmpeg(base), isNull);
    expect(await validateFfmpeg(base.copyWith(ffmpegPath: fake.path)), isNull);
    expect(
      await validateFfmpeg(base.copyWith(ffmpegPath: p.join(tmp.path, 'nope'))),
      startsWith('ffmpeg 路径不存在'),
    );
    expect(
      await validateFfmpeg(base.copyWith(
        ffmpegPath: fake.path,
        ffprobePath: p.join(tmp.path, 'nope2'),
      )),
      startsWith('ffprobe 路径不存在'),
    );
  });

  test('配置路径进引擎显式覆盖：resolveFfmpegExecutable / ffprobe 直接返回它', () {
    ffmpegPathOverride = '/opt/fushi/ffmpeg';
    ffprobePathOverride = '/opt/fushi/ffprobe';
    expect(resolveFfmpegExecutable(), '/opt/fushi/ffmpeg');
    expect(resolveFfprobeExecutable(), '/opt/fushi/ffprobe');
    expect(ffmpegExplicitOverride(), '/opt/fushi/ffmpeg');
  });
}

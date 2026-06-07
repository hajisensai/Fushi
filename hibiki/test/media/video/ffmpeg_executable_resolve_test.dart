import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';

/// 桌面 ffmpeg 可执行解析优先级：HIBIKI_FFMPEG 覆盖 > 程序旁捆绑 ffmpeg > 系统 PATH。
/// 让没装 ffmpeg 的电脑也能用捆绑的（开箱即用），同时保留显式覆盖与 PATH 回退。
void main() {
  group('resolveFfmpegExecutableFrom 优先级', () {
    test('HIBIKI_FFMPEG 覆盖最高优先', () {
      expect(
        resolveFfmpegExecutableFrom(
            override: '/opt/ff/ffmpeg', bundledPath: '/app/ffmpeg'),
        '/opt/ff/ffmpeg',
      );
    });

    test('无覆盖时用程序旁捆绑 ffmpeg', () {
      expect(
        resolveFfmpegExecutableFrom(override: null, bundledPath: '/app/ffmpeg'),
        '/app/ffmpeg',
      );
      // 空白覆盖视同无覆盖。
      expect(
        resolveFfmpegExecutableFrom(
            override: '   ', bundledPath: r'C:\Hibiki\ffmpeg.exe'),
        r'C:\Hibiki\ffmpeg.exe',
      );
    });

    test('无覆盖无捆绑回退系统 PATH 的 ffmpeg', () {
      expect(
        resolveFfmpegExecutableFrom(override: null, bundledPath: null),
        'ffmpeg',
      );
      expect(
        resolveFfmpegExecutableFrom(override: '', bundledPath: ''),
        'ffmpeg',
      );
    });
  });
}

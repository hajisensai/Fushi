import 'package:flutter_test/flutter_test.dart';

import '../../tool/make_download_manifest.dart';

void main() {
  group('包分片来源守卫', () {
    test('主 app 仓库的 release 地址被判为危险', () {
      final String? reason = hazardousReleaseHost(
        'https://github.com/hajisensai/Fushi/releases/download/pack-1/x.000',
      );
      expect(reason, isNotNull);
      expect(reason, contains('mirror-releases.yml'));
    });

    test('大小写不同也拦得住——GitHub 的 owner/repo 在 URL 里不区分大小写', () {
      expect(
        hazardousReleaseHost(
          'https://github.com/HajiSensai/fushi/releases/download/pack-1/x.000',
        ),
        isNotNull,
      );
    });

    test('独立仓库 fushi-pack 放行', () {
      expect(
        hazardousReleaseHost(
          'https://github.com/hajisensai/fushi-pack/releases/download/pack-1',
        ),
        isNull,
      );
    });

    test('非 github 主机放行', () {
      expect(hazardousReleaseHost('https://dl.wrds.xyz/parts/pack-1'), isNull);
    });

    test('真实参数解析路径会拒绝该地址 —— 钉住调用点，不只是纯函数', () {
      // 只测纯函数的话，把 _Args.parse 里的调用整行删掉，上面四条照样全绿。
      // 这条走真实校验入口，让「守卫函数还在但没人调用」当场红。
      // 参数刻意在 parse 阶段就触发：不会去读 --input 指的文件。
      expect(
        () => parseArgsForTest(<String>[
          '--input', 'not-read.zip',
          '--whole-url', 'https://dl.wrds.xyz/pack.zip',
          '--part-base-url',
          'https://github.com/hajisensai/Fushi/releases/download/pack-1',
        ]),
        throwsA(isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('mirror-releases.yml'),
        )),
      );
    });

    test('换成 fushi-pack 后同一组参数不再被拒', () {
      expect(
        () => parseArgsForTest(<String>[
          '--input', 'not-read.zip',
          '--whole-url', 'https://dl.wrds.xyz/pack.zip',
          '--part-base-url',
          'https://github.com/hajisensai/fushi-pack/releases/download/pack-1',
          '--out-dir', 'out',
        ]),
        returnsNormally,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/desktop_ctl_host.dart';
import 'package:fushi_cli/fushi_cli.dart';

void main() {
  group('classifyCtlOpenTarget', () {
    CtlOpenResult classify(
      String target, {
      bool videoModuleEnabled = true,
      bool exists = true,
    }) => classifyCtlOpenTarget(
      target,
      videoModuleEnabled: videoModuleEnabled,
      fileExists: (_) => exists,
    );

    test('查词深链', () {
      expect(classify('fushi://lookup?word=猫').kind, CtlOpenKind.lookup);
    });

    test('存在的视频文件', () {
      expect(classify('/v/ep01.mkv').kind, CtlOpenKind.video);
    });

    test('视频文件不存在 → 拒绝并说明', () {
      final CtlOpenResult result = classify('/v/ep01.mkv', exists: false);
      expect(result.accepted, isFalse);
      expect(result.reason, contains('/v/ep01.mkv'));
    });

    test('视频模块关闭 → 拒绝（与 argv 路径的模块门一致，不入库）', () {
      expect(
        classify('/v/ep01.mkv', videoModuleEnabled: false).accepted,
        isFalse,
      );
    });

    test('不认识的目标 → 拒绝，而不是像 argv 那样静默忽略', () {
      expect(classify('/books/a.epub').accepted, isFalse);
      expect(classify('https://example.com').accepted, isFalse);
    });
  });
}

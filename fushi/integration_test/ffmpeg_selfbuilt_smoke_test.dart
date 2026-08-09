import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';

/// 设备冒烟：证明「自编」ffmpeg-kit（arthenica 源码 NDK r25 重编最小变体）在 Android 16
/// 上不仅能加载（修了 BUG-122 的 JNI_OnLoad 崩溃），而且原生 ffmpeg/ffprobe **真能执行**。
/// 在真机/模拟器跑：flutter test integration_test/ffmpeg_selfbuilt_smoke_test.dart -d <id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('自编 ffmpeg -version 返回 rc=0 且含 ffmpeg version', (tester) async {
    final session = await FFmpegKit.execute('-version');
    final ReturnCode? rc = await session.getReturnCode();
    final String out = (await session.getOutput()) ?? '';
    expect(ReturnCode.isSuccess(rc), isTrue,
        reason: 'rc=${rc?.getValue()} out=$out');
    expect(out.toLowerCase().contains('ffmpeg version'), isTrue, reason: out);
  });

  testWidgets('自编 ffprobe -version 返回 rc=0', (tester) async {
    final session = await FFprobeKit.execute('-version');
    final ReturnCode? rc = await session.getReturnCode();
    expect(ReturnCode.isSuccess(rc), isTrue, reason: 'rc=${rc?.getValue()}');
  });
}

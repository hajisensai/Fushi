import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:path/path.dart' as p;

/// 从当前目录向上找到含 `native/galgame_hook` 的仓库根。测试的 cwd 在本地是
/// `hibiki/`、在 CI 上也可能是仓库根，故不写死层级；找不到返回 null。
Directory? _findRepoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    final Directory candidate =
        Directory(p.join(dir.path, 'native', 'galgame_hook'));
    if (candidate.existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  group('资源↔文本配对窗口两侧同值（BUG-1143）', () {
    test(
        'native kKirikiriFollowingTextWindowMs == Dart kGalVoicePairingWindowMs',
        () {
      final Directory? root = _findRepoRoot();
      expect(
        root,
        isNotNull,
        reason: '找不到仓库根（应含 native/galgame_hook），无法校验窗口一致性',
      );
      final File header = File(
        p.join(root!.path, 'native', 'galgame_hook', 'hook',
            'voice_resource_pairing.h'),
      );
      expect(header.existsSync(), isTrue,
          reason: '缺少 ${header.path}——配对窗口守卫失去依据');

      final RegExp pattern = RegExp(
        r'kKirikiriFollowingTextWindowMs\s*=\s*(\d+)',
      );
      final Match? match = pattern.firstMatch(header.readAsStringSync());
      expect(match, isNotNull,
          reason:
              'voice_resource_pairing.h 里找不到 kKirikiriFollowingTextWindowMs');

      final int nativeWindowMs = int.parse(match!.group(1)!);
      expect(
        nativeWindowMs,
        kGalVoicePairingWindowMs,
        reason: 'native 打标窗口与 Dart 收标窗口必须同值：native 在窗口内配上就把 '
            'TextSlot::seq 写进资源名，Dart 若用更小的窗口就会拒收自己这条 marker，'
            '而带 marker 的资源又不允许回退时间窗兜底，结果整句降级成 loopback。',
      );
    });

    test('eventId 命中时，native 窗口上界内的资源必须被接受', () {
      // native 保证 0 <= textTs - resourceTick <= kKirikiriFollowingTextWindowMs，
      // 故上界处的资源是合法配对，不能因为消费端窗口更窄而被丢掉（修复前 1000ms
      // 上界会让 1000~1500ms 这段变成死区）。
      const int textTsMs = 600000;
      const int tick = textTsMs - kGalVoicePairingWindowMs;
      expect(
        pickPairedVoiceOgg(
          oggFileNames: <String>['${tick}_hibiki_textseq83_yuz_001_0012.ogg'],
          textTsMs: textTsMs,
          textEventId: 83,
        ),
        '${tick}_hibiki_textseq83_yuz_001_0012.ogg',
      );
    });

    test('eventId 不同的带标资源仍不得被时间窗猜给本行', () {
      // 放宽窗口不能顺带放宽「带 marker 的资源只认自己那条文本」这条纪律。
      const int textTsMs = 600000;
      const int tick = textTsMs - 220;
      expect(
        pickPairedVoiceOgg(
          oggFileNames: <String>['${tick}_hibiki_textseq99_yuz_001_0012.ogg'],
          textTsMs: textTsMs,
          textEventId: 83,
        ),
        isNull,
      );
    });
  });
}

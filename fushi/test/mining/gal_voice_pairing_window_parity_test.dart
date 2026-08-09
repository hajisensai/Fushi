import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 从当前目录向上找到含 `native/galgame_hook` 的仓库根。测试的 cwd 在本地是
/// `fushi/`、在 CI 上也可能是仓库根，故不写死层级；找不到返回 null。
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
  group('资源↔文本配对窗口两侧同值（BUG-1159）', () {
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
          oggFileNames: <String>['${tick}_fushi_textseq83_yuz_001_0012.ogg'],
          textTsMs: textTsMs,
          textEventId: 83,
        ),
        '${tick}_fushi_textseq83_yuz_001_0012.ogg',
      );
    });

    test('eventId 不同的带标资源仍不得被时间窗猜给本行', () {
      // 放宽窗口不能顺带放宽「带 marker 的资源只认自己那条文本」这条纪律。
      const int textTsMs = 600000;
      const int tick = textTsMs - 220;
      expect(
        pickPairedVoiceOgg(
          oggFileNames: <String>['${tick}_fushi_textseq99_yuz_001_0012.ogg'],
          textTsMs: textTsMs,
          textEventId: 83,
        ),
        isNull,
      );
    });
    test('AI6 资源晚于文本时，稳定事件 ID 仍可在窄窗内配对', () {
      // KiriKiri 先资源后文本，AI6 则先文本后读取 voice.arc；两条链都必须先由
      // native 写入精确 TextSlot::seq，消费端才允许双向时间窗。
      const int textTsMs = 600000;
      const int tick = textTsMs + 300;
      expect(
        pickPairedVoiceOgg(
          oggFileNames: <String>['${tick}_fushi_textseq83_yuz_001_0012.ogg'],
          textTsMs: textTsMs,
          textEventId: 83,
        ),
        '${tick}_fushi_textseq83_yuz_001_0012.ogg',
      );
    });
  });

  // C++ 行为测试在 native/galgame_hook/tests/luna_text_replay_test.cpp，但那套 ctest
  // 只在 voice-hook-helper workflow（workflow_dispatch + push develop）里跑，**PR 时不是门**。
  // 下面这组结构守卫扫真实 C++ 源码，把「改回错误判据」这件事挡在 PR 的 flutter test 门上。
  // 切片锚点（含 `// ── Luna_Start` 这种注释锚点）在原始源码上取，取到函数体后一律先
  // [maskComments] 再断言——否则把 NoteFace 之类的调用降级成注释也照样命中 contains。
  group('native 文本线程/折叠判据结构守卫（BUG-1159 / BUG-1175）', () {
    late String selectorSource;
    late String injectorSource;

    setUpAll(() {
      final Directory? root = _findRepoRoot();
      expect(root, isNotNull, reason: '找不到仓库根（应含 native/galgame_hook）');
      selectorSource = File(
        p.join(root!.path, 'native', 'galgame_hook', 'include',
            'luna_text_selector.h'),
      ).readAsStringSync();
      injectorSource = File(
        p.join(root.path, 'native', 'galgame_hook', 'injector',
            'injector_main.cpp'),
      ).readAsStringSync();
    });

    test('折叠判据是块级分解，不是「开头二倍就截断」', () {
      // BUG-1175 打回原因：前缀判据会把「わかったわかった、もう行くよ」腰斩成
      // 「わかった」。块级判据要求整串能拆成 s1 s1 s2 s2 …，尾巴拆不动就原样放行。
      final int foldStart = selectorSource.indexOf(
        'inline int LunaNormalizedTextLength(',
      );
      expect(foldStart, greaterThanOrEqualTo(0),
          reason: '找不到 LunaNormalizedTextLength——折叠守卫失去依据');
      final int foldEnd = selectorSource.indexOf(
        'LunaNormalizedTextLengthForHook',
        foldStart,
      );
      expect(foldEnd, greaterThan(foldStart));
      final String body =
          maskComments(selectorSource.substring(foldStart, foldEnd));
      expect(
        body.contains('if (doubled) return k;'),
        isFalse,
        reason: '检测到「开头二倍即返回 k」的前缀判据——它会静默截掉合法叠句后面的正文',
      );
      expect(
        body.contains('block[static_cast<size_t>(i + 2 * k)]'),
        isTrue,
        reason: '折叠必须先确认尾巴可完整拆成成对重复块，才允许折叠首块',
      );
    });

    test('hook 面 id 只去掉 ctx，必须保留 ctx2（split H 码的角色名/正文分类）', () {
      final int faceStart = selectorSource.indexOf(
        'inline uint64_t LunaTextFaceIdFrom(',
      );
      expect(faceStart, greaterThanOrEqualTo(0),
          reason: '找不到 LunaTextFaceIdFrom——分面守卫失去依据');
      final int faceEnd = selectorSource.indexOf('\n}', faceStart);
      expect(faceEnd, greaterThan(faceStart));
      final String body =
          maskComments(selectorSource.substring(faceStart, faceEnd));
      expect(
        body.contains('&ctx2, sizeof(ctx2)'),
        isTrue,
        reason: 'ctx2 是 split H 码显式声明的语义分类，从 face 里去掉会把角色名混进正文流',
      );
      expect(
        body.contains('&ctx,'),
        isFalse,
        reason: 'ctx 是调用点（返回地址），留在 face 里就等于没修 BUG-1159',
      );
    });

    test('injector 仍为每一行登记 face（v13 消费期按 hook 面放行的唯一来源）', () {
      // BUG-1159：同一 hook 面在不同剧情分支下调用点 ctx 会变，thread_id 随之变，只按
      // thread_id 精确匹配会把整段台词丢掉。v13 把选定线程的过滤从采集期挪到消费期
      // （native 每条线程写自己那条道、一行不丢），放行判据也跟着挪到 Dart 的文本消费点；
      // 它按 face 放行，而 face 是 native 在这里算好、随 TextSlot::face_id 带出去的。
      // 所以这条登记必须继续为**每一行**执行——漏一行，那一行的 face 就是 0，消费期只能
      // 退回精确匹配，BUG-1159 原样复发。
      final int fnStart = injectorSource.indexOf('bool LunaShouldWriteLine(');
      expect(fnStart, greaterThanOrEqualTo(0),
          reason: '找不到 LunaShouldWriteLine——face 登记守卫失去依据');
      final int fnEnd = injectorSource.indexOf(
        '// ── Luna_Start',
        fnStart,
      );
      expect(fnEnd, greaterThan(fnStart));
      final String body =
          maskComments(injectorSource.substring(fnStart, fnEnd));
      // 位置在（剥过注释的）函数体内取：挡住「调用被注释掉」的假绿，也挡住「函数体里
      // 没有、却命中了文件后面别处那一处」的越界命中。
      final int noteAt =
          body.indexOf('g_lunaTextSelector.NoteFace(thread_id, face_id);');
      expect(noteAt, greaterThanOrEqualTo(0),
          reason: 'LunaShouldWriteLine 必须显式调用 NoteFace 登记 hook 面');
      // v13：采集期不得再做选定线程准入 —— 在这里丢掉的行，用户换线程后永远追不回来。
      expect(
        body,
        isNot(contains('g_lunaTextSelector.AcceptsLine(')),
        reason: '选定线程过滤已挪到消费期（见 GalHookSessionController.'
            '_acceptsLineFromSelectedThread）；采集期再丢行就白分道了',
      );
      // face 登记必须**无条件**发生在伪影判定之外的路径上，否则伪影线程一转正就没有 face。
      expect(body.indexOf('is_artifact'), lessThan(noteAt),
          reason: '伪影行先挡掉，其余每一行都要登记 face');
    });
  });
}

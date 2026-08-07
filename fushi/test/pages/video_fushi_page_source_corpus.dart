import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus.dart';
import '../helpers/source_guard.dart';

/// TODO-590: `video_fushi_page.dart` 正被分批拆成主壳 + `video_fushi/*.part.dart`
/// 一组 part 文件（零行为重构，照搬 TODO-589 reader_fushi 范式）。原来逐文件硬编码
/// 读单文件的静态守卫，凡断言落在已搬出主壳的方法体里，必须改读这份「合并语料」：
/// 主壳 + 全部 part 文件按固定顺序拼接（主壳在前，保 build 域内 widget 相对顺序断言）。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _VideoFushiPageState` 成员，主壳
/// 顶层 class / 常量 / 其它方法照搬不动，所以基于方法签名 / 字符串切片的守卫逻辑零改写，
/// 只把数据源从「单文件」换成「合并语料」。
///
/// **part 清单从磁盘枚举，不是手写常量**（TODO-2707）：这份清单**实测已经漏过两个**——
/// `flicker_notice.part.dart` 与 `quality.part.dart` 落地后没人回来补清单，落在它们里面
/// 的负向（`isNot`）断言一直真空通过。枚举 + 排序让新 part 自动进语料；契约由
/// `video_fushi_page_source_corpus_test.dart` 锁住。
const String _videoFushiShell =
    'lib/src/pages/implementations/video_fushi_page.dart';
const String kVideoFushiPartDir = 'lib/src/pages/implementations/video_fushi';

/// 主壳 + 磁盘上全部 `*.part.dart`（按路径排序，保证跨机器/跨次运行顺序确定）。
List<String> videoFushiPageFiles() => partCorpusFiles(
      shell: _videoFushiShell,
      partDir: kVideoFushiPartDir,
    );

/// TODO-1000: the media-degradation ladder (GIF -> cue-time still frame ->
/// current-decoded-frame fallback), the no-audio abort (BUG-296) and the
/// AnkiMiningContext assembly were extracted out of _mineVideoCard into the
/// shared ImmersionMiningEngine (_mineVideoCard now delegates to it). The static
/// guards that used to assert those tokens *inside* _mineVideoCard still protect
/// the exact same behaviours -- they just live in the engine now. So the guard
/// corpus also exposes the engine + request source; guards scan the shell shim
/// for the OSD/abort wiring and the engine for the extractor ordering. Pure
/// relocation, assertion intent unchanged.
const List<String> _immersionMiningEngineFiles = <String>[
  'lib/src/mining/immersion_mining_engine.dart',
  'lib/src/mining/immersion_mining_request.dart',
];

/// 读「视频页合并语料」：主壳 + 全部 part 文件拼成单个字符串，供静态守卫切片/断言。
/// 统一把 CRLF 归一成 LF，与逐文件守卫此前的隐式假设一致。
String readVideoFushiSource() => readPartCorpus(videoFushiPageFiles());

/// TODO-1000: read the ImmersionMiningEngine + request source (LF-normalised),
/// where the media-degradation ladder / no-audio abort / AnkiMiningContext
/// assembly moved out of _mineVideoCard. Guards scan this for the extractor
/// wiring while still scanning the video corpus for the shell OSD/abort glue.
String readImmersionMiningEngineSource() {
  final StringBuffer buffer = StringBuffer();
  for (final String path in _immersionMiningEngineFiles) {
    buffer.writeln(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
  }
  return buffer.toString();
}

/// BUG-1301 之后淡入淡出的曲线/指针/焦点三项契约搬进了共享组件
/// [FadingChromeGate]（`lib/src/utils/components/fading_chrome_gate.dart`），
/// 调用点只剩 `visible` / `duration`。守卫因此必须**跟着组件走**：调用点断
/// 「走了 FadingChromeGate 且没覆盖默认曲线」，组件源码断「默认曲线就是
/// easeInOut、且 IgnorePointer + AnimatedOpacity 都在」。把两半拆开断，任一
/// 半被改坏都当场红；只断调用点的旧写法则会被合法重构打断（本次 CI 红的成因）。
const String kFadingChromeGatePath =
    'lib/src/utils/components/fading_chrome_gate.dart';

/// 共享淡出门控自身仍满足「默认 easeInOut + IgnorePointer + AnimatedOpacity」。
///
/// 四条全是**要求型**（isTrue）断言，所以判据必须剥注释：裸 `contains` 下
/// 「把实现删光、把同样的字面量留在注释里」是完全合法的骗绿写法（TODO-2715）。
/// 组件构造走 [containsIdentifierCall]（`IgnorePointer(` 的左边界，防
/// `MyIgnorePointer(` 顶包），字面量走 [containsCodeLine]（只认代码行）。
void expectFadingChromeGateContract() {
  final String gate = File(kFadingChromeGatePath).readAsStringSync();
  expect(containsCodeLine(gate, 'this.curve = Curves.easeInOut'), isTrue,
      reason: 'FadingChromeGate 默认曲线必须是 easeInOut（调用点不传即取此值）；'
          '注释里写着这句不算实现');
  expect(containsIdentifierCall(gate, 'IgnorePointer'), isTrue,
      reason: '淡出后必须 IgnorePointer 不拦点击；注释里提到它不算实现');
  expect(containsIdentifierCall(gate, 'AnimatedOpacity'), isTrue,
      reason: '淡入淡出必须由 AnimatedOpacity 实现；注释里提到它不算实现');
  expect(containsCodeLine(gate, 'curve: curve'), isTrue,
      reason: 'AnimatedOpacity 必须真把 curve 透传下去，否则默认值形同虚设；'
          '注释里写着这句不算实现');
}

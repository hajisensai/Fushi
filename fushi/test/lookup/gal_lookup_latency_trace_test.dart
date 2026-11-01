import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_latency_trace.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

GalLookupHit _hit({int seq = 7, int publish = 0, int dispatch = 0}) =>
    GalLookupHit(
      seq: seq,
      line: 'テスト',
      providerKind: 1,
      providerId: 1,
      charIndex: 0,
      sourceLength: 1,
      charCount: 3,
      textGeneration: 1,
      geometryGeneration: 1,
      coordinateSpace: 1,
      writingMode: 0,
      glyphX: 0,
      glyphY: 0,
      glyphW: 10,
      glyphH: 10,
      viewW: 100,
      viewH: 100,
      submit: true,
      publishQpcUs: publish,
      dispatchQpcUs: dispatch,
    );

void main() {
  late int now;
  late List<String> lines;

  setUp(() {
    GalLookupLatencyTrace.resetForTesting();
    now = 0;
    lines = <String>[];
    GalLookupLatencyTrace.clock = () => now;
    GalLookupLatencyTrace.sink = lines.add;
  });

  tearDown(GalLookupLatencyTrace.resetForTesting);

  test('一次查词只写一行，含跨进程段与逐段耗时', () {
    now = 10000;
    GalLookupLatencyTrace.begin(_hit(publish: 2000, dispatch: 9000));
    now = 11000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.run);
    now = 15000;
    GalLookupLatencyTrace.mark(
      GalLookupLatencyStage.search,
      detail: 'entries=3',
    );
    now = 40000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.presented);
    GalLookupLatencyTrace.finish('ok');

    expect(lines, hasLength(1));
    expect(
      lines.single,
      'gal-latency seq=7 ok cold total=38.0(from-hook) | '
      'pub=2000 hook→poll=7.0 poll→dart=1.0 run=1.0 search=4.0 present=25.0 | '
      'entries=3',
    );
    expect(GalLookupLatencyTrace.active, isNull);
  });

  test('同一阶段只记首次；收尾后再打点不再输出', () {
    GalLookupLatencyTrace.begin(_hit());
    now = 2000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.measured);
    now = 9000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.measured);
    GalLookupLatencyTrace.finish('ok');
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.presented);
    GalLookupLatencyTrace.finish('ok');

    expect(lines, hasLength(1));
    expect(lines.single, contains('measure=2.0'));
    expect(lines.single, contains('(from-dart)'));
  });

  test('新 submit 把在途记录以 superseded 收尾，且只有第一次是 cold', () {
    GalLookupLatencyTrace.begin(_hit(seq: 1));
    GalLookupLatencyTrace.begin(_hit(seq: 2));
    GalLookupLatencyTrace.finish('ok');

    expect(lines, hasLength(2));
    expect(lines[0], startsWith('gal-latency seq=1 superseded cold'));
    expect(lines[1], startsWith('gal-latency seq=2 ok'));
    expect(lines[1], isNot(contains('cold')));
  });

  test('发布时刻晚于收到时刻（时钟不同源）时退回 Dart 起点', () {
    now = 1000;
    GalLookupLatencyTrace.begin(_hit(publish: 5000, dispatch: 6000));
    now = 3000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.presented);
    GalLookupLatencyTrace.finish('ok');

    expect(lines.single, contains('total=2.0(from-dart)'));
    expect(lines.single, isNot(contains('hook→poll')));
  });

  test('宿主 perf 明细只认预期形状', () {
    expect(
      galLookupHostPerfDetail(<String, Object>{
        'inject': 12.4,
        'render': 30,
        'measure': -1,
      }),
      'js[inject=12 render=30 measure=-]',
    );
    expect(galLookupHostPerfDetail(null), isNull);
    expect(galLookupHostPerfDetail(3), isNull);
  });

  test('captureReady 握手明细区分 rAF 与兜底计时器', () {
    expect(
      galLookupCaptureReadyPerfDetail(<String, Object>{
        'raf1': 48.6,
        'ready': 120,
        'by': 'timer',
      }),
      'arm[at=- raf1=49 ready=120 by=timer] longtask[sum=- n=- max=-]',
    );
    expect(galLookupCaptureReadyPerfDetail(<Object>[]), isNull);
  });

  test('桌面路由单独计数，从 Dart 收到算起，冷启动各自判定', () {
    now = 1000;
    GalLookupLatencyTrace.begin(_hit(seq: 3));
    GalLookupLatencyTrace.finish('ok');
    now = 2000;
    final GalLookupLatencyTrace desk = GalLookupLatencyTrace.beginDesktop();
    expect(desk.source, 'desktop');
    now = 2500;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.search);
    now = 4000;
    GalLookupLatencyTrace.mark(GalLookupLatencyStage.presented);
    GalLookupLatencyTrace.finish('ok');
    expect(
      lines.last,
      'desktop-latency seq=1 ok cold total=2.0(from-dart) | '
      'search=0.5 present=1.5',
    );
    GalLookupLatencyTrace.beginDesktop();
    GalLookupLatencyTrace.finish('ok');
    expect(lines.last, startsWith('desktop-latency seq=2 ok |'));
  });
}

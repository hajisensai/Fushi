import 'package:fushi/src/startup/startup_timeline.dart';
import 'package:test/test.dart';

void main() {
  setUp(StartupTimeline.debugReset);
  tearDown(StartupTimeline.debugReset);

  group('StartupTimeline', () {
    test('没 begin 过：mark / seal 都是空操作（弹窗 / 悬浮词典入口）', () {
      StartupTimeline.mark('binding');
      expect(StartupTimeline.marks, isEmpty);
      expect(StartupTimeline.seal(), isNull);
    });

    test('按调用顺序记阶段，累计时间单调不减', () {
      StartupTimeline.begin();
      StartupTimeline.mark('binding');
      StartupTimeline.mark('runApp');
      StartupTimeline.mark('home-build');

      final List<StartupMark> marks = StartupTimeline.marks;
      expect(marks.map((StartupMark m) => m.phase), <String>[
        'binding',
        'runApp',
        'home-build',
      ]);
      expect(marks[0].elapsedMicros, greaterThanOrEqualTo(0));
      expect(
        marks[1].elapsedMicros,
        greaterThanOrEqualTo(marks[0].elapsedMicros),
      );
      expect(
        marks[2].elapsedMicros,
        greaterThanOrEqualTo(marks[1].elapsedMicros),
      );
    });

    test('seal 之后不再记，重复 seal 返回 null', () {
      StartupTimeline.begin();
      StartupTimeline.mark('binding');
      final String? sealed = StartupTimeline.seal();
      expect(sealed, isNotNull);

      StartupTimeline.mark('late');
      expect(StartupTimeline.marks.map((StartupMark m) => m.phase), <String>[
        'binding',
      ]);
      expect(StartupTimeline.seal(), isNull);
    });

    test('seal 之后再 begin 不重新开表', () {
      StartupTimeline.begin();
      StartupTimeline.seal();
      StartupTimeline.begin();
      StartupTimeline.mark('again');
      expect(StartupTimeline.marks, isEmpty);
    });

    test('没有原生段：total + start + 各段', () {
      StartupTimeline.begin();
      StartupTimeline.mark('binding');
      StartupTimeline.mark('runApp');
      final String sealed = StartupTimeline.seal()!;

      expect(
        sealed,
        matches(
          RegExp(r'^total=\d+ms start=\S+ \| binding=\d+ \| runApp=\d+$'),
        ),
      );
    });

    test('有原生段：进程创建到 main() 之前的各段拼在前面', () {
      StartupTimeline.begin();
      StartupTimeline.mark('binding');
      final int nowUs = DateTime.now().microsecondsSinceEpoch;
      // 进程 2 秒前创建：0.5 秒进 wWinMain，再 1 秒引擎建好，剩下的是引擎起 Dart。
      final NativeStartupTrace native = NativeStartupTrace(
        processStartMicros: nowUs - 2000000,
        marks: <StartupMark>[
          StartupMark('winmain', nowUs - 1500000),
          StartupMark('engine-create', nowUs - 500000),
        ],
      );
      final String sealed = StartupTimeline.seal(native: native)!;

      expect(sealed, contains('native[winmain=500 engine-create=1000 '));
      final RegExpMatch head = RegExp(
        r'^total=(\d+)ms pre-dart=(\d+)ms dart=(\d+)ms start=\S+ \| ',
      ).firstMatch(sealed)!;
      final int total = int.parse(head.group(1)!);
      final int preDart = int.parse(head.group(2)!);
      final int dart = int.parse(head.group(3)!);
      // begin() 与上面取 now 之间只隔几行代码：pre-dart 就是那 2 秒（留 0.2 秒余量）。
      expect(preDart, inInclusiveRange(1800, 2000));
      expect((total - preDart - dart).abs(), lessThanOrEqualTo(1));
      expect(sealed, matches(RegExp(r'to-dart-main=\d+\] \| binding=\d+$')));
    });
  });

  group('NativeStartupTrace.tryParse', () {
    test('通道返回的形状', () {
      final NativeStartupTrace? trace = NativeStartupTrace.tryParse(
        <Object?, Object?>{
          'processStartMicros': 1700000000000000,
          'marks': <Object?>[
            <Object?>['winmain', 1700000000100000],
            <Object?>['engine-create', 1700000000900000],
          ],
        },
      );

      expect(trace, isNotNull);
      expect(trace!.processStartMicros, 1700000000000000);
      expect(trace.marks.map((StartupMark m) => m.phase), <String>[
        'winmain',
        'engine-create',
      ]);
      expect(trace.marks.last.elapsedMicros, 1700000000900000);
    });

    test('形状不对一律 null，不抛', () {
      expect(NativeStartupTrace.tryParse(null), isNull);
      expect(NativeStartupTrace.tryParse('nope'), isNull);
      expect(
        NativeStartupTrace.tryParse(<Object?, Object?>{'marks': <Object?>[]}),
        isNull,
      );
      expect(
        NativeStartupTrace.tryParse(<Object?, Object?>{
          'processStartMicros': 0,
          'marks': <Object?>[],
        }),
        isNull,
      );
      expect(
        NativeStartupTrace.tryParse(<Object?, Object?>{
          'processStartMicros': 1,
          'marks': <Object?>[
            <Object?>['only-name'],
          ],
        }),
        isNull,
      );
      expect(
        NativeStartupTrace.tryParse(<Object?, Object?>{
          'processStartMicros': 1,
          'marks': <Object?>[
            <Object?>['name', 'not-int'],
          ],
        }),
        isNull,
      );
    });
  });
}

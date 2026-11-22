/// 框架的宿主侧能力：参数类型（颜色 / 文本 / 素材包 / 预设 / 条件显隐 / 分组）与通用参数面板、
/// 背景层组合、素材库、封面加载器、逐帧驱动的 dt 与只跟歌词时间的监听口。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/pages/implementations/music/music_lyric_visualizer_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;

import 'visualizer_test_helpers.dart';

String _l() => 'label';

const LyricVisualizerTuningSection _adv = LyricVisualizerTuningSection(
  key: 'adv',
  label: _advLabel,
);
const LyricVisualizerTuningSection _deep = LyricVisualizerTuningSection(
  key: 'deep',
  label: _deepLabel,
  parent: _adv,
);
String _advLabel() => 'Advanced';
String _deepLabel() => 'Deeper';

bool _showOn(LyricVisualizerTuning v) => v.flag('show', false);

final List<LyricVisualizerTuningSpec> _specs = <LyricVisualizerTuningSpec>[
  const LyricVisualizerToggleSpec(key: 'show', label: _l, initial: true),
  const LyricVisualizerSliderSpec(
    key: 'size',
    label: _l,
    min: 0,
    max: 1,
    initial: 0.5,
    visibleWhen: _showOn,
  ),
  const LyricVisualizerTextSpec(
    key: 'title',
    label: _l,
    initial: 'hi',
    maxLength: 5,
    section: _adv,
  ),
  const LyricVisualizerColorSpec(
    key: 'tint',
    label: _l,
    initial: Color(0xFF112233),
    section: _deep,
  ),
];

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(milliseconds: 1200);

  @override
  Duration get duration => const Duration(minutes: 4);
}

void main() {
  group('参数类型', () {
    test('颜色：整数 / 十六进制 / 坏值', () {
      const LyricVisualizerColorSpec c = LyricVisualizerColorSpec(
        key: 'c',
        label: _l,
        initial: Color(0xFF000000),
      );
      expect(c.normalize('#ff8800'), 0xFFFF8800);
      expect(c.normalize('#80FF8800'), 0xFFFF8800, reason: '不透明钉死');
      expect(c.normalize(0x11223344), 0xFF223344);
      expect(c.normalize('nope'), 0xFF000000);
      expect(lyricVisualizerParseHexColor('#abc'), const Color(0xFFAABBCC));
      expect(lyricVisualizerHexOf(const Color(0xFFFF8800)), '#FF8800');
      final LyricVisualizerTuning t = LyricVisualizerTuning(
        const <LyricVisualizerTuningSpec>[c],
        const <String, Object?>{'c': '#010203'},
      );
      expect(t.color('c', Colors.white), const Color(0xFF010203));
    });

    test('文本截断、素材包名校验', () {
      const LyricVisualizerTextSpec s = LyricVisualizerTextSpec(
        key: 't',
        label: _l,
        maxLength: 3,
      );
      expect(s.normalize('abcdef'), 'abc');
      expect(s.normalize(3), '');
      const LyricVisualizerAssetPackSpec a = LyricVisualizerAssetPackSpec(
        key: 'a',
        label: _l,
        style: 'cappella',
      );
      expect(a.normalize('my-pack_1'), 'my-pack_1');
      expect(a.normalize('../etc'), 'default');
    });

    test('预设：默认值叠上预设', () {
      const LyricVisualizerTuningPreset p = LyricVisualizerTuningPreset(
        id: 'p1',
        label: _l,
        values: <String, Object>{'show': false},
      );
      final Map<String, Object> v = p.apply(_specs);
      expect(v['show'], false);
      expect(v['size'], 0.5);
      expect(
        _deep.path.map((LyricVisualizerTuningSection s) => s.key),
        <String>['adv', 'deep'],
      );
    });
  });

  group('背景层', () {
    test('请求解析', () {
      expect(
        resolveLyricVisualizerBackground(
          LyricVisualizerBackgroundRequest.selected,
          null,
        )!.id,
        lyricVisualizerFluidBackgroundId,
      );
      expect(
        resolveLyricVisualizerBackground(
          LyricVisualizerBackgroundRequest.selected,
          'solid',
        )!.id,
        'solid',
      );
      expect(
        resolveLyricVisualizerBackground(
          LyricVisualizerBackgroundRequest.none,
          'fluid',
        )!.id,
        'solid',
      );
      expect(
        resolveLyricVisualizerBackground(
          const LyricVisualizerBackgroundRequest.specific('bogus'),
          'solid',
        )!.id,
        'solid',
      );
      expect(
        resolveLyricVisualizerBackground(
          LyricVisualizerBackgroundRequest.transparent,
          'solid',
        ),
        isNull,
      );
      final Set<String> ids = <String>{
        for (final LyricVisualizerBackgroundEntry b
            in lyricVisualizerBackgrounds)
          b.id,
      };
      expect(ids, hasLength(lyricVisualizerBackgrounds.length));
    });

    test('每个样式都显式声明背景请求，且按默认参数解析得出', () {
      for (final MapEntry<LyricVisualizerMode, LyricVisualizerEntry> e
          in lyricVisualizerRegistry.entries) {
        final LyricVisualizerTuning t = LyricVisualizerTuning.defaults(
          e.value.tunings,
        );
        final LyricVisualizerBackgroundRequest r = e.value.backgroundFor(t);
        expect(
          r,
          e.value.background(t),
          reason: '${e.key.name} 的 backgroundFor 必须就是它声明的 background',
        );
        if (r.kind == LyricVisualizerBackgroundKind.specific) {
          expect(
            lyricVisualizerBackgrounds.any(
              (LyricVisualizerBackgroundEntry b) => b.id == r.id,
            ),
            isTrue,
            reason: '${e.key.name} 指定了不存在的背景 ${r.id}',
          );
        }
      }
    });

    Future<void> pumpHost(
      WidgetTester tester,
      LyricVisualizerMode mode, {
      String? backgroundId,
      LyricVisualizerTheme? theme,
    }) async {
      // 先清场：宿主换样式走 AnimatedSwitcher，新旧两层会同时在树上。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicLyricVisualizerView(
              mode: mode,
              timeline: sampleWordTimeline(),
              clock: _Clock(),
              offsetMs: 0,
              playing: false,
              trackUid: 't',
              tunings: const <String, Map<String, Object?>>{},
              fontScale: 1,
              onExit: () {},
              onPickStyle: () {},
              backgroundId: backgroundId,
              theme: theme,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('宿主按请求画背景', (WidgetTester tester) async {
      await pumpHost(tester, LyricVisualizerMode.luminous);
      // 默认背景是歌词页背景：宿主不重复画。
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_background_fluid')),
        findsNothing,
      );
      await pumpHost(
        tester,
        LyricVisualizerMode.luminous,
        backgroundId: 'solid',
      );
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_background_solid')),
        findsOneWidget,
      );
      // 样式不要共享背景（still）：铺纯色底。
      await pumpHost(tester, LyricVisualizerMode.still);
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_background_solid')),
        findsOneWidget,
      );
      // 主题配色覆盖落到背景色上。
      await pumpHost(
        tester,
        LyricVisualizerMode.still,
        theme: const LyricVisualizerTheme(
          palette: LyricVisualizerPaletteOverride(
            background: Color(0xFF123456),
          ),
        ),
      );
      final ColoredBox box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('music_visualizer_background_solid'),
          ),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(box.color, const Color(0xFF123456));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('通用参数面板', () {
    Future<List<Map<String, Object?>?>> pumpPanel(
      WidgetTester tester, {
      Map<String, Object?> stored = const <String, Object?>{},
      List<LyricVisualizerTuningPreset> presets =
          const <LyricVisualizerTuningPreset>[],
    }) async {
      final List<Map<String, Object?>?> results = <Map<String, Object?>?>[];
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: GestureDetector(
                  key: const ValueKey<String>('open'),
                  onTap: () async {
                    results.add(
                      await Navigator.of(ctx).push(
                        MaterialPageRoute<Map<String, Object?>>(
                          builder: (_) => Scaffold(
                            body: LyricVisualizerTuningPanel.specs(
                              title: _l,
                              specs: _specs,
                              stored: stored,
                              presets: presets,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('条件显隐', (WidgetTester tester) async {
      await pumpPanel(tester);
      final Finder size = find.byKey(
        const ValueKey<String>('music_visualizer_tuning_size'),
      );
      expect(size, findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('music_visualizer_tuning_show')),
      );
      await tester.pumpAndSettle();
      expect(size, findsNothing);
    });

    testWidgets('分组可嵌套、默认收起', (WidgetTester tester) async {
      await pumpPanel(tester);
      final Finder text = find.byKey(
        const ValueKey<String>('music_visualizer_tuning_title'),
      );
      expect(text, findsNothing);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(text, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_tuning_tint')),
        findsNothing,
      );
      await tester.tap(find.text('Deeper'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_tuning_tint')),
        findsOneWidget,
      );
    });

    testWidgets('颜色十六进制 + 文本落库只存改动项', (WidgetTester tester) async {
      final List<Map<String, Object?>?> results = await pumpPanel(tester);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deeper'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('music_visualizer_hex_tint')),
          matching: find.byType(EditableText),
        ),
        '#FF0000',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('music_visualizer_tuning_title'),
          ),
          matching: find.byType(EditableText),
        ),
        'abc',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('music_visualizer_tuning_done')),
      );
      await tester.pumpAndSettle();
      expect(results.single, <String, Object?>{
        'tint': 0xFFFF0000,
        'title': 'abc',
      });
    });

    testWidgets('预设一键套用', (WidgetTester tester) async {
      final List<Map<String, Object?>?> results = await pumpPanel(
        tester,
        presets: const <LyricVisualizerTuningPreset>[
          LyricVisualizerTuningPreset(
            id: 'p1',
            label: _l,
            values: <String, Object>{'show': false, 'size': 0.9},
          ),
        ],
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('music_visualizer_preset_p1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('music_visualizer_tuning_done')),
      );
      await tester.pumpAndSettle();
      expect(results.single, <String, Object?>{'show': false, 'size': 0.9});
    });
  });

  group('素材库', () {
    late Directory tmp;
    late LyricVisualizerAssetStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('viz_assets_');
      store = LyricVisualizerAssetStore(Directory('${tmp.path}/root'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    File src(String name) =>
        File('${tmp.path}/$name')..writeAsBytesSync(<int>[1, 2, 3]);

    test('导入 / 列出 / 删除 / 上限', () async {
      final List<File> added = await store
          .importFiles('cappella', 'avatars', <String>[
            src('a.png').path,
            src('b c.JPG').path,
            src('notes.txt').path,
            src('d.webp').path,
          ], maxFiles: 2);
      expect(added, hasLength(2));
      final List<File> listed = await store.list('cappella', 'avatars');
      expect(listed.map((File f) => f.uri.pathSegments.last), <String>[
        '0000_a.png',
        '0001_b_c.jpg',
      ]);
      expect(await store.listPacks('cappella'), <String>['avatars']);
      await store.delete('cappella', 'avatars', listed.first);
      expect(await store.list('cappella', 'avatars'), hasLength(1));
      await store.importFiles('cappella', 'avatars', <String>[
        src('e.png').path,
      ]);
      // 序号接着最大的往后排，不覆盖。
      expect(
        (await store.list(
          'cappella',
          'avatars',
        )).map((File f) => f.uri.pathSegments.last),
        <String>['0001_b_c.jpg', '0002_e.png'],
      );
      await store.deletePack('cappella', 'avatars');
      expect(await store.listPacks('cappella'), isEmpty);
    });

    test('拒绝越界路径与非法名', () async {
      expect(() => store.packDir('../x', 'p'), throwsArgumentError);
      expect(
        () => store.delete('cappella', 'p', src('outside.png')),
        throwsArgumentError,
      );
    });
  });

  group('封面加载', () {
    test('没有封面：provider 为 null，加载器不抛', () {
      expect(lyricVisualizerCoverProvider(null), isNull);
      expect(lyricVisualizerCoverProvider('Z:/no/such/file.png'), isNull);
      expect(
        lyricVisualizerCoverProvider('https://example.com/a.jpg'),
        isNotNull,
      );
      final LyricVisualizerImageLoader l = LyricVisualizerImageLoader()
        ..load(null);
      expect(l.image, isNull);
      l.dispose();
    });
  });

  group('逐帧驱动', () {
    testWidgets('dt 与只跟歌词时间的监听口', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock(1000);
      final LyricVisualizerContext c = visualizerContextFor(
        lyricVisualizerEntryOf(LyricVisualizerMode.still),
        clock: clock,
        playing: false,
      );
      late LyricVisualizerTicks ticks;
      await tester.pumpWidget(
        LyricVisualizerFrame(
          context: c,
          builder: (BuildContext _, LyricVisualizerTicks t) {
            ticks = t;
            return const SizedBox.shrink();
          },
        ),
      );
      int timeNotes = 0;
      final ValueListenable<int> timeMs = ticks.timeMs;
      timeMs.addListener(() => timeNotes++);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(timeNotes, 0, reason: '暂停时歌词时间不动，不通知');
      clock.positionMs = 2000;
      await tester.pump(const Duration(milliseconds: 16));
      expect(timeNotes, 1);
      expect(timeMs.value, 2000);
      expect(ticks.value.dt, inInclusiveRange(0.0, 0.1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('pumpVisualizerAcross：主题 + 强度 + 音频 + 字号', (
    WidgetTester tester,
  ) async {
    await pumpVisualizerAcross(
      tester,
      lyricVisualizerEntryOf(LyricVisualizerMode.luminous),
      fontScale: 1.4,
      theme: const LyricVisualizerTheme(
        wordColors: <String, Color>{'光': Color(0xFFFF0000)},
        intensity: LyricVisualizerIntensity.chaotic,
      ),
      audio: SyntheticVisualizerAudio(),
      offsetMs: 200,
      timesMs: const <int>[0, 1100, 3600, 12300],
    );
  });
}

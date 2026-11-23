/// AI 歌词动画主题的缓存（每首落盘、可撤销）、控制器（没指派提供商不发请求、自动生成、换歌竞态）、
/// 面板与宿主入口。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_music_visualizer_theme_assistant.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_controller.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_sheet.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_store.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/pages/implementations/music/music_lyric_visualizer_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;

import 'visualizer_test_helpers.dart';

AiMusicVisualizerTheme _theme(int bg) => AiMusicVisualizerTheme(
  light: kAiVisualizerFallbackLight,
  dark: AiVisualizerThemeVariant(
    background: Color(0xFF000000 | bg),
    text: const Color(0xFFF8FAFC),
    accent: const Color(0xFF7DD3FC),
    secondary: const Color(0xFFCBD5E1),
    name: 'n$bg',
    wordColors: const <String, Color>{'星': Color(0xFFFFD700)},
  ),
  intensity: LyricVisualizerIntensity.chaotic,
);

final AiProviderConfig _provider = AiProviderConfig(
  id: 'p',
  presetId: kAiCustomPresetId,
  name: 'p',
  baseUrl: Uri.parse('https://example.com/v1'),
  apiKey: 'k',
  model: 'm',
);

class _Gen {
  int calls = 0;
  final List<String?> titles = <String?>[];
  Completer<AiMusicVisualizerTheme?>? gate;
  AiMusicVisualizerTheme? Function() next = () => _theme(0x101010);
  AiChatFailure? error;

  Future<AiMusicVisualizerTheme?> call({
    required AiProviderConfig provider,
    required String? title,
    required String? artist,
    required String lyricsSnippet,
  }) async {
    calls++;
    titles.add(title);
    if (gate != null) return gate!.future;
    if (error != null) throw error!;
    return next();
  }
}

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(milliseconds: 1200);

  @override
  Duration get duration => const Duration(minutes: 4);
}

void main() {
  late Directory dir;
  late LyricVisualizerAiThemeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_ai_theme_');
    store = LyricVisualizerAiThemeStore(directory: () async => dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('缓存', () {
    test('每首一文件、往返一致；坏文件当空；空记录删文件', () async {
      expect(await store.load('a'), LyricVisualizerAiThemeRecord.empty);
      final LyricVisualizerAiThemeRecord r = LyricVisualizerAiThemeRecord.empty
          .replacedWith(_theme(1), nowMs: 5);
      await store.save('a/b?c', r);
      final File f = File(
        '${dir.path}/${LyricVisualizerAiThemeStore.fileNameFor('a/b?c')}',
      );
      expect(f.existsSync(), isTrue);
      final LyricVisualizerAiThemeRecord back = await store.load('a/b?c');
      expect(back.current, _theme(1));
      expect(back.hasPrevious, isTrue);
      expect(back.previous, isNull);
      expect(back.updatedAtMs, 5);
      f.writeAsStringSync('{garbage');
      expect(await store.load('a/b?c'), LyricVisualizerAiThemeRecord.empty);
      await store.save('a/b?c', LyricVisualizerAiThemeRecord.empty);
      expect(f.existsSync(), isFalse);
    });

    test('撤销是互换：可以再撤销回来', () {
      final LyricVisualizerAiThemeRecord one = LyricVisualizerAiThemeRecord
          .empty
          .replacedWith(_theme(1), nowMs: 1);
      final LyricVisualizerAiThemeRecord two = one.replacedWith(
        _theme(2),
        nowMs: 2,
      );
      expect(two.previous, _theme(1));
      final LyricVisualizerAiThemeRecord undone = two.reverted(nowMs: 3);
      expect(undone.current, _theme(1));
      expect(undone.reverted(nowMs: 4).current, _theme(2));
      expect(
        LyricVisualizerAiThemeRecord.empty.reverted(nowMs: 1),
        same(LyricVisualizerAiThemeRecord.empty),
      );
    });
  });

  group('控制器', () {
    LyricVisualizerAiThemeController make(
      _Gen gen, {
      AiProviderConfig? provider,
      bool auto = false,
      bool ai = true,
    }) => LyricVisualizerAiThemeController(
      resolveProvider: () => provider,
      autoGenerate: () => auto,
      aiEnabled: () => ai,
      store: store,
      generator: gen.call,
      nowMs: () => 42,
    );

    const LyricVisualizerAiThemeTrack a = LyricVisualizerAiThemeTrack(
      uid: 'a',
      title: 'A',
    );
    const LyricVisualizerAiThemeTrack b = LyricVisualizerAiThemeTrack(
      uid: 'b',
      title: 'B',
    );

    test('没指派提供商：手动生成不发请求、进 noProvider；自动生成静默跳过', () async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(gen, auto: true);
      addTearDown(c.dispose);
      await c.attach(a);
      expect(gen.calls, 0);
      expect(c.status, LyricVisualizerAiThemeStatus.idle);
      expect(await c.generate(), isFalse);
      expect(gen.calls, 0);
      expect(c.status, LyricVisualizerAiThemeStatus.noProvider);
    });

    test('AI 模块关着：不发请求、入口不显示、缓存的主题也不套', () async {
      await store.save(
        'a',
        LyricVisualizerAiThemeRecord.empty.replacedWith(_theme(1), nowMs: 1),
      );
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(
        gen,
        provider: _provider,
        auto: true,
        ai: false,
      );
      addTearDown(c.dispose);
      await c.attach(a);
      expect(c.available, isFalse);
      expect(await c.generate(), isFalse);
      expect(gen.calls, 0);
      expect(c.themeFor('a', Brightness.dark), isNull);
    });

    test('生成 → 落盘 → 新控制器重开直接复用，不再请求', () async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(gen, provider: _provider);
      addTearDown(c.dispose);
      await c.attach(a);
      expect(await c.generate(), isTrue);
      expect(gen.calls, 1);
      expect(
        c.themeFor('a', Brightness.dark)!.intensity,
        LyricVisualizerIntensity.chaotic,
      );
      expect(c.themeFor('b', Brightness.dark), isNull);

      final _Gen gen2 = _Gen();
      final LyricVisualizerAiThemeController c2 = make(
        gen2,
        provider: _provider,
        auto: true,
      );
      addTearDown(c2.dispose);
      await c2.attach(a);
      expect(gen2.calls, 0);
      expect(c2.current, _theme(0x101010));
    });

    test('自动生成只给从没有记录的歌；改回封面取色后不再自动生成', () async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(
        gen,
        provider: _provider,
        auto: true,
      );
      addTearDown(c.dispose);
      await c.attach(a);
      expect(gen.calls, 1);
      expect(c.current, isNotNull);
      await c.clear();
      expect(c.current, isNull);
      final LyricVisualizerAiThemeController c2 = make(
        gen,
        provider: _provider,
        auto: true,
      );
      addTearDown(c2.dispose);
      await c2.attach(a);
      expect(gen.calls, 1);
      // 改回封面取色可撤销。
      await c2.revert();
      expect(c2.current, _theme(0x101010));
    });

    test('重新生成留上一版，撤销换回、再撤销又回来；结果都落盘', () async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(gen, provider: _provider);
      addTearDown(c.dispose);
      await c.attach(a);
      await c.generate();
      gen.next = () => _theme(0x202020);
      await c.generate();
      expect(c.current, _theme(0x202020));
      await c.revert();
      expect(c.current, _theme(0x101010));
      expect((await store.load('a')).current, _theme(0x101010));
      await c.revert();
      expect(c.current, _theme(0x202020));
    });

    test('失败：AiChatFailure 记短码；回复不可用记 empty；原主题不动', () async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c = make(gen, provider: _provider);
      addTearDown(c.dispose);
      await c.attach(a);
      await c.generate();
      gen.error = const AiChatFailure('http_401');
      expect(await c.generate(), isFalse);
      expect(c.status, LyricVisualizerAiThemeStatus.failed);
      expect(c.failure, 'http_401');
      expect(c.current, _theme(0x101010));
      gen
        ..error = null
        ..next = () => null;
      await c.generate();
      expect(c.failure, 'empty');
    });

    test('生成途中换歌：结果写进原来那首的缓存，不套到新歌上', () async {
      final _Gen gen = _Gen()..gate = Completer<AiMusicVisualizerTheme?>();
      final LyricVisualizerAiThemeController c = make(gen, provider: _provider);
      addTearDown(c.dispose);
      await c.attach(a);
      final Future<bool> pending = c.generate();
      expect(c.status, LyricVisualizerAiThemeStatus.generating);
      await c.attach(b);
      gen.gate!.complete(_theme(7));
      expect(await pending, isTrue);
      expect(c.track!.uid, 'b');
      expect(c.current, isNull);
      expect((await store.load('a')).current, _theme(7));
    });
  });

  group('界面', () {
    testWidgets('面板：没提供商时点生成出提示与「打开 AI 设置」', (WidgetTester tester) async {
      int opened = 0;
      final LyricVisualizerAiThemeController c =
          LyricVisualizerAiThemeController(
            resolveProvider: () => null,
            autoGenerate: () => false,
            aiEnabled: () => true,
            store: store,
            generator: _Gen().call,
            openAiSettings: (BuildContext _) async => opened++,
          );
      addTearDown(c.dispose);
      await tester.runAsync(
        () => c.attach(const LyricVisualizerAiThemeTrack(uid: 'a')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LyricVisualizerAiThemePanel(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('music_visualizer_ai_theme_generate'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('music_visualizer_ai_theme_no_provider'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('music_visualizer_ai_theme_open_settings'),
        ),
      );
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('面板：有主题时显示预览；撤销按钮可用', (WidgetTester tester) async {
      final _Gen gen = _Gen();
      final LyricVisualizerAiThemeController c =
          LyricVisualizerAiThemeController(
            resolveProvider: () => _provider,
            autoGenerate: () => false,
            aiEnabled: () => true,
            store: store,
            generator: gen.call,
          );
      addTearDown(c.dispose);
      await tester.runAsync(() async {
        await c.attach(const LyricVisualizerAiThemeTrack(uid: 'a'));
        await c.generate();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(body: LyricVisualizerAiThemePanel(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_ai_theme_preview')),
        findsOneWidget,
      );
      expect(find.text('星'), findsOneWidget);
    });

    testWidgets('宿主：给了控制器才有 AI 主题按钮；主题配色套进样式', (WidgetTester tester) async {
      await tester.runAsync(
        () => store.save(
          't',
          LyricVisualizerAiThemeRecord.empty.replacedWith(
            _theme(0x123456),
            nowMs: 1,
          ),
        ),
      );
      final LyricVisualizerAiThemeController c =
          LyricVisualizerAiThemeController(
            resolveProvider: () => null,
            autoGenerate: () => false,
            aiEnabled: () => true,
            store: store,
            generator: _Gen().call,
          );
      addTearDown(c.dispose);
      Widget host(LyricVisualizerAiThemeController? ai) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: MusicLyricVisualizerView(
            mode: LyricVisualizerMode.still,
            timeline: sampleWordTimeline(),
            clock: _Clock(),
            offsetMs: 0,
            playing: false,
            trackUid: 't',
            tunings: const <String, Map<String, Object?>>{},
            fontScale: 1,
            onExit: () {},
            onPickStyle: () {},
            aiTheme: ai,
          ),
        ),
      );
      await tester.pumpWidget(host(null));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_ai_theme')),
        findsNothing,
      );
      // 读缓存是真 IO，在假时钟里落不了地：先在真异步里把这首挂上（宿主再 attach 同一首是空操作，
      // 宿主自己 attach 的路径由控制器测试覆盖）。
      await tester.runAsync(
        () => c.attach(const LyricVisualizerAiThemeTrack(uid: 't')),
      );
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.current, _theme(0x123456));
      expect(
        find.byKey(const ValueKey<String>('music_visualizer_ai_theme')),
        findsOneWidget,
      );
      // still 不要共享背景：宿主铺的纯色底就是主题背景。
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((ColoredBox b) => b.color == const Color(0xFF123456)),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

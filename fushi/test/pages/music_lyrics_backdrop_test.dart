import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_music.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

double _chroma(Color c) {
  final double hi = [c.r, c.g, c.b].reduce((a, b) => a > b ? a : b);
  final double lo = [c.r, c.g, c.b].reduce((a, b) => a < b ? a : b);
  return hi - lo;
}

/// [w]×[h] 的 RGBA：左半 [left]、右半 [right]（不透明）。
Uint8List _halves(int w, int h, Color left, Color right) {
  final Uint8List out = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final Color c = x < w / 2 ? left : right;
      final int i = (y * w + x) * 4;
      out[i] = (c.r * 255).round();
      out[i + 1] = (c.g * 255).round();
      out[i + 2] = (c.b * 255).round();
      out[i + 3] = 255;
    }
  }
  return out;
}

Iterable<SettingsItem> _allItems(SettingsDestination d) sync* {
  for (final SettingsSection s in d.sections) {
    yield* s.items;
  }
}

void main() {
  group('musicBackdropColorMatrix', () {
    test('dark: saturation 1 only scales by the scrim keep factor', () {
      final List<double> m = musicBackdropColorMatrix(
        saturation: 1,
        brightness: Brightness.dark,
      );
      const Color c = Color(0xFF80C040);
      final Color out = applyMusicBackdropColorMatrix(m, c);
      expect(out.r * 255, closeTo(0x80 * kMusicBackdropDarkScrimKeep, 1));
      expect(out.g * 255, closeTo(0xC0 * kMusicBackdropDarkScrimKeep, 1));
      expect(out.b * 255, closeTo(0x40 * kMusicBackdropDarkScrimKeep, 1));
      expect(out.a, 1);
    });

    test('light: lifts toward white so dark lyrics stay readable', () {
      final List<double> m = musicBackdropColorMatrix(
        saturation: 1,
        brightness: Brightness.light,
      );
      final Color black = applyMusicBackdropColorMatrix(
        m,
        const Color(0xFF000000),
      );
      expect(
        black.r * 255,
        closeTo(255 * (1 - kMusicBackdropLightScrimKeep), 1),
      );
      final Color white = applyMusicBackdropColorMatrix(
        m,
        const Color(0xFFFFFFFF),
      );
      expect(white.r, closeTo(1, 0.01));
    });

    test('grays are untouched by saturation; saturation scales chroma', () {
      const Color gray = Color(0xFF808080);
      const Color color = Color(0xFFC06040);
      final Color g1 = applyMusicBackdropColorMatrix(
        musicBackdropColorMatrix(saturation: 2, brightness: Brightness.dark),
        gray,
      );
      expect(_chroma(g1), closeTo(0, 0.01));
      double chromaAt(double s) => _chroma(
        applyMusicBackdropColorMatrix(
          musicBackdropColorMatrix(saturation: s, brightness: Brightness.dark),
          color,
        ),
      );
      expect(chromaAt(0), closeTo(0, 0.01));
      expect(chromaAt(0.5), lessThan(chromaAt(1)));
      expect(chromaAt(2), greaterThan(chromaAt(1)));
    });
  });

  group('extractMusicBackdropPalette', () {
    test('two-color cover yields both colors and a matching grid', () {
      const Color red = Color(0xFFD02020);
      const Color blue = Color(0xFF2030D0);
      final MusicBackdropPalette p = extractMusicBackdropPalette(
        _halves(32, 32, red, blue),
        32,
        32,
      );
      expect(p.dominant, containsAll(<int>[red.toARGB32(), blue.toARGB32()]));
      expect(p.gridSize, kMusicMeshGridSize);
      expect(p.grid, hasLength(kMusicMeshGridSize * kMusicMeshGridSize));
      expect(p.grid.first, red.toARGB32());
      expect(p.grid.last, blue.toARGB32());
    });

    test('transparent / malformed input yields an empty palette', () {
      expect(
        extractMusicBackdropPalette(Uint8List(16 * 16 * 4), 16, 16).isEmpty,
        isTrue,
      );
      expect(
        extractMusicBackdropPalette(Uint8List(10), 16, 16).isEmpty,
        isTrue,
      );
    });

    test('caps the number of dominant colors', () {
      final Uint8List rgba = Uint8List(64 * 4);
      for (int i = 0; i < 64; i++) {
        rgba[i * 4] = (i * 37) % 256;
        rgba[i * 4 + 1] = (i * 91) % 256;
        rgba[i * 4 + 2] = (i * 53) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final MusicBackdropPalette p = extractMusicBackdropPalette(
        rgba,
        8,
        8,
        maxColors: 3,
      );
      expect(p.dominant, hasLength(3));
    });
  });

  group('mesh geometry', () {
    test('corners fixed, edge points stay on their edge at every phase', () {
      const int n = kMusicMeshGridSize;
      for (final double phase in <double>[0, 0.13, 0.5, 0.77]) {
        final List<Offset> pts = musicMeshControlPoints(n, phase);
        expect(pts.first, Offset.zero);
        expect(pts.last, const Offset(1, 1));
        for (int c = 0; c < n; c++) {
          expect(pts[c].dy, 0);
          expect(pts[(n - 1) * n + c].dy, 1);
        }
        for (int r = 0; r < n; r++) {
          expect(pts[r * n].dx, 0);
          expect(pts[r * n + n - 1].dx, 1);
        }
        for (final Offset o in pts) {
          expect(o.dx, inInclusiveRange(0, 1));
          expect(o.dy, inInclusiveRange(0, 1));
        }
      }
      // 一周无缝：相位 0 与 1 同形。
      final List<Offset> a = musicMeshControlPoints(n, 0);
      final List<Offset> b = musicMeshControlPoints(n, 1);
      for (int i = 0; i < a.length; i++) {
        expect((a[i] - b[i]).distance, lessThan(1e-9));
      }
    });

    test('surface passes through the control points', () {
      const int n = kMusicMeshGridSize;
      final List<int> colors = <int>[
        for (int i = 0; i < n * n; i++)
          0xFF000000 | (i * 15 << 16) | (255 - i * 15),
      ];
      final MusicMeshSurface s = buildMusicMeshSurface(
        points: musicMeshControlPoints(n, 0),
        colors: colors,
        n: n,
        subdivisions: 4,
      );
      expect(s.side, (n - 1) * 4 + 1);
      expect(s.positions, hasLength(s.side * s.side * 2));
      expect(s.indices, hasLength((s.side - 1) * (s.side - 1) * 6));
      expect(s.colors.first.toUnsigned(32), colors.first);
      expect(s.colors.last.toUnsigned(32), colors.last);
      expect(s.positions[0], 0);
      expect(s.positions[s.positions.length - 1], 1);
    });

    test('render size keeps aspect and stays within budget', () {
      final Size big = musicBackdropRenderSize(const Size(3840, 2160));
      expect(big.longestSide, lessThanOrEqualTo(240));
      expect(big.width / big.height, closeTo(16 / 9, 0.05));
      final Size small = musicBackdropRenderSize(const Size(200, 100));
      expect(small.longestSide, greaterThanOrEqualTo(64));
      expect(musicBackdropRenderSize(Size.zero), Size.zero);
    });
  });

  test('style pref round-trips; unknown falls back to mesh gradient', () {
    for (final MusicLyricsBackdropStyle s in MusicLyricsBackdropStyle.values) {
      expect(MusicLyricsBackdropStyle.fromPref(s.prefValue), s);
    }
    expect(
      MusicLyricsBackdropStyle.fromPref('bogus'),
      MusicLyricsBackdropStyle.meshGradient,
    );
    expect(
      MusicLyricsBackdropStyle.fromPref(null),
      MusicLyricsBackdropStyle.meshGradient,
    );
  });

  group('preferences', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('defaults: flowing, mesh gradient, 100% saturation', () {
      expect(repo.musicLyricsBackdropAnimate, isTrue);
      expect(repo.musicLyricsBackdropStyle, 'mesh');
      expect(repo.musicLyricsBackdropSaturation, 1.0);
    });

    test('values round-trip', () async {
      await repo.setMusicLyricsBackdropAnimate(false);
      await repo.setMusicLyricsBackdropStyle('pixi');
      await repo.setMusicLyricsBackdropSaturation(1.7);
      expect(repo.musicLyricsBackdropAnimate, isFalse);
      expect(repo.musicLyricsBackdropStyle, 'pixi');
      expect(repo.musicLyricsBackdropSaturation, 1.7);
    });
  });

  test('music settings expose the lyrics background group', () {
    final List<SettingsItem> items = _allItems(
      buildMusicDestination(),
    ).toList();
    SettingsItem byId(String id) =>
        items.firstWhere((SettingsItem i) => i.id == id);

    final SettingsSegmentedItem<bool> motion =
        byId('music.lyrics_backdrop_animate') as SettingsSegmentedItem<bool>;
    expect(motion.defaultValue, isTrue);
    expect(motion.options.map((o) => o.value), <bool>[true, false]);

    final SettingsSegmentedItem<MusicLyricsBackdropStyle> style =
        byId('music.lyrics_backdrop_style')
            as SettingsSegmentedItem<MusicLyricsBackdropStyle>;
    expect(style.defaultValue, MusicLyricsBackdropStyle.meshGradient);
    expect(style.options.map((o) => o.value), MusicLyricsBackdropStyle.values);

    final SettingsSliderItem saturation =
        byId('music.lyrics_backdrop_saturation') as SettingsSliderItem;
    expect(saturation.min, 50);
    expect(saturation.max, 200);
    expect(saturation.divisions, 15);
    expect(saturation.defaultValue, 100);
  });

  group('MusicLyricsBackdrop rendering', () {
    late int renders;

    setUp(() {
      renders = 0;
      MusicLyricsBackdrop.debugOnFrameRendered = (_) => renders++;
    });

    tearDown(() => MusicLyricsBackdrop.debugOnFrameRendered = null);

    Widget host(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: SizedBox(width: 800, height: 600, child: child),
    );

    testWidgets('static mode renders the offscreen frame exactly once', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(const MusicLyricsBackdrop(coverPath: null, animate: false)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(renders, 1);
    });

    testWidgets('classic never animates even in flowing mode', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const MusicLyricsBackdrop(
            coverPath: null,
            style: MusicLyricsBackdropStyle.classic,
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(renders, 1);
    });

    testWidgets('flowing mode re-renders at a throttled (~30fps) rate', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const MusicLyricsBackdrop(coverPath: null)));
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      expect(renders, greaterThan(10));
      // 一秒 ≈ 30 帧：远低于逐 vsync。
      expect(renders, lessThanOrEqualTo(32));
      // 卸载后驱动停止，不再要帧。
      await tester.pumpWidget(host(const SizedBox()));
      final int after = renders;
      await tester.pump(const Duration(seconds: 1));
      expect(renders, after);
    });

    testWidgets('reduced motion freezes flowing mode', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const SizedBox(
              width: 800,
              height: 600,
              child: MusicLyricsBackdrop(coverPath: null),
            ),
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(renders, 1);
    });
  });
}

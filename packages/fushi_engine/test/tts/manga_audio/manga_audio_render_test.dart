import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:test/test.dart';

MangaRenderedLine _line(int page, List<int> blocks, {bool ph = false}) =>
    MangaRenderedLine(
      lineId: 'p${page}b${blocks.join('.')}',
      page: page,
      blocks: blocks,
      speaker: 'A',
      kind: CastLineKind.spoken,
      beatMs: 0,
      file: 'p${page}b${blocks.join('.')}.wav',
      durationMs: 1000,
      text: 'x',
      placeholder: ph,
    );

void main() {
  test('href / fragment helpers round trip', () {
    expect(parseMangaPageHref(mangaPageHref(12)), 12);
    expect(parseMangaPageHref('pdf-page-1'), isNull);
    expect(parseMangaBlocksFragment(mangaBlocksFragment(<int>[3, 0])), <int>[
      3,
      0,
    ]);
    expect(parseMangaBlocksFragment('1,x'), isEmpty);
  });

  test('manifest round trip, timeline and backfill', () async {
    final MangaRenderManifest m = MangaRenderManifest(
      pageCount: 3,
      engineSignature: 'sig',
      lines: <MangaRenderedLine>[
        _line(0, <int>[1]),
        _line(2, <int>[0, 2], ph: true),
      ],
      pages: <int, MangaPageDirective>{
        1: const MangaPageDirective(holdMs: 100),
      },
    );
    expect(m.audioFiles, <String>['p0b1.wav', 'p2b0.2.wav']);
    expect(m.placeholderCount, 1);
    final MangaTimeline tl = m.timeline();
    expect(tl.segments.length, 3);
    expect(tl.segments[1].durationMs, 100);
    expect(tl.lines[1].placeholder, isTrue);
    expect(
      m.timeline(mode: MangaPlaybackMode.listenOnly).segments[1].durationMs,
      0,
    );

    expect(
      m.replaceLine(
        'p2b0.2',
        (MangaRenderedLine l) => l.replaced(
          file: 'p2b0.2_r.wav',
          durationMs: 1500,
          placeholder: false,
          voice: 'r1',
        ),
      ),
      isTrue,
    );
    expect(m.placeholderCount, 0);

    final Directory dir = Directory.systemTemp.createTempSync('manga_render');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File f = MangaRenderManifest.fileFor(dir, 'book');
    await m.save(f);
    final MangaRenderManifest back = (await MangaRenderManifest.load(f))!;
    expect(back.lines[1].voice, 'r1');
    expect(back.lines[1].durationMs, 1500);
    expect(back.pages[1]!.holdMs, 100);
    expect(back.engineSignature, 'sig');
  });

  group('外部管线写的未知键（拍板 pr4255a）', () {
    Map<String, Object?> externalJson() => <String, Object?>{
      'v': 7,
      'pageCount': 3,
      'ocr': 'sig',
      'generator': <String, Object?>{'name': 'ext-pipeline', 'rev': 3},
      'notes': 'keep me',
      'lines': <Object?>[
        <String, Object?>{
          'id': 'p0b1',
          'p': 0,
          'b': <int>[1],
          's': 'A',
          'k': 'spoken',
          'f': 'p0b1.wav',
          'ms': 1000,
          't': 'x',
          'emotion': 'happy',
          'take': <int>[1, 2],
        },
        <String, Object?>{
          'id': 'p2b0',
          'p': 2,
          'b': <int>[0],
          's': 'B',
          'k': 'spoken',
          'f': 'p2b0.wav',
          'ms': 800,
          't': 'y',
          'emotion': 'sad',
        },
      ],
      'pages': <String, Object?>{
        '1': <String, Object?>{'hold': 300, 'src': 'user', 'bgm': 'calm'},
      },
    };

    test('round trip keeps unknown top-level and per-line keys', () async {
      final MangaRenderManifest m = MangaRenderManifest.fromJson(
        externalJson(),
      )!;
      expect(m.extras.keys, <String>['generator', 'notes']);
      expect(m.lineExtras['p0b1'], <String, Object?>{
        'emotion': 'happy',
        'take': <int>[1, 2],
      });
      final Directory dir = Directory.systemTemp.createTempSync('manga_ext');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File f = File('${dir.path}/manifest.json');
      await m.save(f);
      final Map<String, Object?> saved =
          jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      expect(saved['generator'], <String, Object?>{
        'name': 'ext-pipeline',
        'rev': 3,
      });
      expect(saved['notes'], 'keep me');
      // app 自己的键 app 说了算：版本号写回 app 的 schema。
      expect(saved['v'], MangaRenderManifest.schemaVersion);
      final List<Object?> lines = saved['lines']! as List<Object?>;
      expect((lines[0]! as Map<String, Object?>)['emotion'], 'happy');
      expect((lines[0]! as Map<String, Object?>)['take'], <Object?>[1, 2]);
      expect((lines[1]! as Map<String, Object?>)['emotion'], 'sad');
      expect((saved['pages']! as Map<String, Object?>)['1'], <String, Object?>{
        'hold': 300,
        'src': 'user',
        'bgm': 'calm',
      });
      // 再读一遍仍是同一份未知字段（多次改写不累积、不丢）。
      final MangaRenderManifest back = (await MangaRenderManifest.load(f))!;
      expect(back.extras, m.extras);
      expect(back.lineExtras, m.lineExtras);
      expect(back.pageExtras, m.pageExtras);
      expect(back.pages[1]!.holdMs, 300);
    });

    test('editing a line keeps its extras', () {
      final MangaRenderManifest m = MangaRenderManifest.fromJson(
        externalJson(),
      )!;
      m.replaceLine(
        'p0b1',
        (MangaRenderedLine l) => l.replaced(
          file: 'p0b1.s5.m4a',
          durationMs: 1200,
          placeholder: false,
          seed: 5,
        ),
      );
      final Map<String, Object?> line =
          (m.toJson()['lines']! as List<Object?>)[0]! as Map<String, Object?>;
      expect(line['f'], 'p0b1.s5.m4a');
      expect(line['ms'], 1200);
      expect(line['seed'], 5);
      expect(line['emotion'], 'happy');
      expect(line['take'], <int>[1, 2]);
    });

    test('extras follow the line id; removed lines drop theirs', () {
      final MangaRenderManifest m = MangaRenderManifest.fromJson(
        externalJson(),
      )!;
      m.lines.removeWhere((MangaRenderedLine l) => l.lineId == 'p0b1');
      final List<Object?> lines = m.toJson()['lines']! as List<Object?>;
      expect(lines, hasLength(1));
      final Map<String, Object?> only = lines[0]! as Map<String, Object?>;
      expect(only['id'], 'p2b0');
      expect(only['emotion'], 'sad');
      expect(only.containsKey('take'), isFalse);
      expect(m.liveLineExtras.keys, <String>['p2b0']);
      // 新清单只收自己有的行的未知字段（整卷重跑拿掉的句子不复活）。
      final Map<String, Map<String, Object?>> original =
          MangaRenderManifest.fromJson(externalJson())!.lineExtras;
      final MangaRenderManifest narrowed = MangaRenderManifest(
        pageCount: 3,
        lines: <MangaRenderedLine>[m.lines.single],
        lineExtras: original,
      );
      expect(narrowed.lineExtras.keys, <String>['p2b0']);
      // 页指令拿掉了，它的未知字段也不写回。
      m.pages.remove(1);
      expect(m.toJson()['pages'], isEmpty);
    });

    test('app-written manifests carry no extras', () {
      final Map<String, Object?> json = MangaRenderManifest(
        pageCount: 1,
        lines: <MangaRenderedLine>[
          _line(0, <int>[0]),
        ],
      ).toJson();
      final MangaRenderManifest back = MangaRenderManifest.fromJson(json)!;
      expect(back.extras, isEmpty);
      expect(back.lineExtras, isEmpty);
      expect(back.pageExtras, isEmpty);
      expect(back.toJson(), json);
    });
  });

  test('out-of-order pages make the manifest invalid', () {
    final Map<String, Object?> json = MangaRenderManifest(
      pageCount: 3,
      lines: <MangaRenderedLine>[
        _line(2, <int>[0]),
        _line(1, <int>[0]),
      ],
    ).toJson();
    expect(MangaRenderManifest.fromJson(json), isNull);
  });
}

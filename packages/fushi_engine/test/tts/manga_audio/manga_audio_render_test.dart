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

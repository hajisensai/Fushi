import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000002';

/// 文件头样本：ISO BMFF `ftyp` box（size + 'ftyp' + 主品牌 + minor + 兼容品牌）。
List<int> _ftyp(String major, List<String> compatible) {
  final List<int> body = <int>[
    ...'ftyp'.codeUnits,
    ...major.codeUnits,
    0, 0, 0, 0, // minor_version
    for (final String b in compatible) ...b.codeUnits,
  ];
  final int size = body.length + 4;
  return <int>[
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...body,
    // ftyp 之后的下一个 box（meta）：不该被当成品牌读。
    0, 0, 0, 12, ...'meta'.codeUnits, ...'avis'.codeUnits,
  ];
}

/// BUG（用户 2026-10-21「我视频怎么没了」）：原生 Fushi 卡面只画 `<img>` 与 `[sound:]`，
/// 视频片段卡（默认视频制卡模式）的 `<video>` / 页内 `<audio>` 与动图 AVIF 被静默丢成
/// 「没有画面 / 一张静图」。判据钉在引擎 renderCard：画不全的卡留在整面 WebView。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('srsFushiCardMediaIsNative', () {
    test('plain still / animated raster <img> stays native', () async {
      for (final String name in <String>[
        'a.jpg',
        'b.webp',
        'c.gif',
        'd.avif',
      ]) {
        expect(
          await srsFushiCardMediaIsNative(<String, String>{
            'Picture': coverMediaRef(name),
            'SentenceAudio': '[sound:s.aac]',
            'ExpressionAudio': '[sound:w.mp3]',
          }),
          isTrue,
          reason: name,
        );
      }
      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': '<div><img src="a.png"><br></div>',
        }),
        isTrue,
      );
      expect(await srsFushiCardMediaIsNative(<String, String>{}), isTrue);
    });

    test('clip cards (mining output) stay native', () async {
      // 与制卡链路同一组生成函数（anki_note_composer.dart）：WebM 片段 + 内嵌单词 /
      // 句子音频，原生卡面用片段播放器与音频按钮画全。
      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': coverMediaRef('clip.webm'),
          'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
          'ExpressionAudio': inlineVideoWordAudioHtml('w.mp3'),
        }),
        isTrue,
      );
      // MP4 片段是 Picture 里的 [sound:clip.mp4]。
      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': coverMediaRef('clip.mp4'),
        }),
        isTrue,
      );
    });

    test(
      'svg, remote, replay buttons and mixed Picture content are not native',
      () async {
        for (final String picture in <String>[
          synchronizedVideoReplayHtml,
          '[sound:a.mp3]', // 非视频的 [sound:]：原生 Picture 没有对应画法
          '<audio src="a.mp3"></audio>',
          '<img src="a.svg">',
          '<img src="data:image/svg+xml;base64,AAAA">',
          '<img src="https://example.com/a.png">',
          '<img src="a.png"> caption',
          '<img alt="no source">',
        ]) {
          expect(
            await srsFushiCardMediaIsNative(<String, String>{
              'Picture': picture,
            }),
            isFalse,
            reason: picture,
          );
        }
      },
    );

    test('probe vetoes images the native decoder cannot fully show', () async {
      final List<String> asked = <String>[];
      Future<bool> probe(String name) async {
        asked.add(name);
        return name != 'anim.avif';
      }

      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': '<img src="anim.avif">',
        }, nativeImage: probe),
        isFalse,
      );
      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': '<img src="still.avif">',
        }, nativeImage: probe),
        isTrue,
      );
      // data: URI 不是媒体库文件，不探测。
      expect(
        await srsFushiCardMediaIsNative(<String, String>{
          'Picture': '<img src="data:image/png;base64,AAAA">',
        }, nativeImage: probe),
        isTrue,
      );
      expect(asked, <String>['anim.avif', 'still.avif']);
    });
  });

  group('srsIsAnimatedAvifHeader', () {
    test('avis in major or compatible brands = animated', () {
      // 用户卡片的真实 AVIF 动图（ffmpeg 出）：主品牌 avis。
      expect(
        srsIsAnimatedAvifHeader(
          _ftyp('avis', <String>['avis', 'avif', 'msf1', 'iso8', 'mif1']),
        ),
        isTrue,
      );
      expect(
        srsIsAnimatedAvifHeader(_ftyp('avif', <String>['mif1', 'avis'])),
        isTrue,
      );
    });

    test('still AVIF, other formats and truncated heads = not animated', () {
      expect(
        srsIsAnimatedAvifHeader(_ftyp('avif', <String>['mif1', 'miaf'])),
        isFalse,
        reason: 'avis after the ftyp box (in meta) must not count',
      );
      expect(srsIsAnimatedAvifHeader('RIFF0000WEBPVP8 '.codeUnits), isFalse);
      expect(srsIsAnimatedAvifHeader(<int>[0, 0, 0]), isFalse);
    });
  });

  group('renderCard', () {
    int t = DateTime.utc(2026, 10, 21, 12).millisecondsSinceEpoch;

    Future<SrsRenderedCard> render(
      SrsDbStore s,
      Map<String, String> fieldsByKey,
    ) async {
      final String note = await s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kProfile, 'Expression'): 'あちら',
          srsFushiCardFieldId(kProfile, 'MainDefinition'):
              '<ol><li>there</li></ol>',
          for (final MapEntry<String, String> e in fieldsByKey.entries)
            srsFushiCardFieldId(kProfile, e.key): e.value,
        },
      );
      final SrsCardCacheRow card = (await s.cardsOfNote(note)).first;
      t += 1000;
      return (await s.renderCard(card.id))!;
    }

    test(
      'clip cards render natively; animated AVIF falls back to the WebView',
      () async {
        final SrsDbStore s = await openTestStore(
          profileUid: kProfile,
          deviceId: 'a',
          now: () => t,
          nativeImageProbe: (String name) async => name != 'anim.avif',
        );

        final SrsRenderedCard still = await render(s, <String, String>{
          'Picture': coverMediaRef('still.jpg'),
          'SentenceAudio': '[sound:s.aac]',
        });
        expect(still.fushiCardDefinitions, isNotNull);

        final SrsRenderedCard clip = await render(s, <String, String>{
          'Picture': coverMediaRef('clip.webm'),
          'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
        });
        expect(clip.fushiCardDefinitions, isNotNull, reason: '片段卡走原生卡面');
        expect(
          clip.fields['Picture'],
          contains('<video class="fushi-inline-video"'),
        );

        final SrsRenderedCard anim = await render(s, <String, String>{
          'Picture': coverMediaRef('anim.avif'),
        });
        expect(anim.fushiCardDefinitions, isNull);
        expect(anim.answer, contains('anim.avif'));
      },
    );
  });
}

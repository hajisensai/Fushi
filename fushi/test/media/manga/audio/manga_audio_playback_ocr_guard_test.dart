// 已入库的漫画有声成品在阅读器里播放时也核对 OCR 签名（设计 §1 / §验收「OCR 重跑后
// 演出稿 / 成品被标记为需重新标注，不带着错位的下标继续播」）。
//
// 判据与导入同一个纯函数 [mangaManifestVolumeMismatch]：这里先用「生成 → 某页 OCR
// 重跑」的真实形状验判据，再静态守住阅读器侧的每个入口（起播、回到阅读器接回会话、
// 播放中 OCR 落定 / 整卷完成 / 缓存补回）都走这一判据，而不是只核页数。
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:path/path.dart' as p;

MokuroBlock _block(String text, double left) => MokuroBlock(
  rectangle: MokuroRect.fromLTRB(left, 0, left + 10, 10),
  isVertical: true,
  fontSize: 12,
  zIndex: 0,
  lines: <String>[text],
);

MokuroPayload _volume(
  List<List<MokuroBlock>> pages, {
  String? engineSignature,
}) => MokuroPayload(
  ocr: engineSignature == null
      ? null
      : MangaOcrMetadata(
          engine: 'e',
          engineSignature: engineSignature,
          schemaVersion: 1,
        ),
  images: <MokuroImage>[
    for (int i = 0; i < pages.length; i++)
      MokuroImage(
        url: 'p$i.jpg',
        size: const MokuroSize(100, 100),
        blocks: pages[i],
      ),
  ],
);

/// 生成端写清单时记下的就是 [mangaPayloadOcrSignature]（`manga_audio_renderer.dart`
/// 把演出稿的签名写进 `ocr`）。
MangaRenderManifest _renderedFrom(MokuroPayload payload) =>
    MangaRenderManifest.fromJson(<String, Object?>{
      'v': 1,
      'pageCount': payload.images.length,
      'ocr': mangaPayloadOcrSignature(payload),
      'lines': <Object?>[
        <String, Object?>{
          'id': 'p0b1',
          'p': 0,
          'b': <int>[1],
          's': 'A',
          'k': 'spoken',
          'f': 'a/p0b1.wav',
          'ms': 900,
          't': 'two',
        },
      ],
    })!;

String _readAloudSource() => File(
  p.join(
    'lib',
    'src',
    'media',
    'manga',
    'reader',
    'manga_fushi',
    'read_aloud.part.dart',
  ),
).readAsStringSync();

/// `name(...) {` 开始到下一个同缩进的 `}` 为止的方法体。
String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final int end = source.indexOf('\n  }\n', start);
  expect(end, greaterThan(start));
  return source.substring(start, end);
}

void main() {
  group('播放端 OCR 签名判据（与导入同一纯函数）', () {
    final List<List<MokuroBlock>> original = <List<MokuroBlock>>[
      <MokuroBlock>[_block('one', 0), _block('two', 20)],
      <MokuroBlock>[_block('three', 0)],
    ];

    test('mokuro 卷：OCR 没变 → 可播；某页重跑块序变了 → ocrMismatch', () {
      final MangaRenderManifest manifest = _renderedFrom(_volume(original));
      expect(mangaManifestVolumeMismatch(manifest, _volume(original)), isNull);

      // 第 0 页重跑：同样两块，顺序换了——块下标 1 指向的已经不是 'two'。
      final MokuroPayload rerun = _volume(<List<MokuroBlock>>[
        <MokuroBlock>[_block('two', 20), _block('one', 0)],
        original[1],
      ]);
      expect(
        mangaManifestVolumeMismatch(manifest, rerun),
        MangaAudioImportResult.ocrMismatch,
      );
    });

    test('引擎签名卷：整卷换引擎重跑完成 → ocrMismatch', () {
      final MangaRenderManifest manifest = _renderedFrom(
        _volume(original, engineSignature: 'eng-1'),
      );
      expect(
        mangaManifestVolumeMismatch(
          manifest,
          _volume(original, engineSignature: 'eng-1'),
        ),
        isNull,
      );
      expect(
        mangaManifestVolumeMismatch(
          manifest,
          _volume(original, engineSignature: 'eng-2'),
        ),
        MangaAudioImportResult.ocrMismatch,
      );
    });
  });

  group('阅读器侧每个入口都按 OCR 签名核对（静态守卫）', () {
    final String src = _readAloudSource();

    test('判据只有一份：_audioMismatch 调 mangaManifestVolumeMismatch，不再只核页数', () {
      expect(
        _methodBody(src, 'MangaAudioImportResult? _audioMismatch('),
        contains('mangaManifestVolumeMismatch(manifest, payload)'),
      );
      expect(src, isNot(contains('manifest.pageCount != pageCount')));
      expect(src, isNot(contains('mangaPayloadOcrSignature')));
    });

    test('起播与接回会话都核对；对不上就停会话并提示，不接宿主', () {
      final String start = _methodBody(
        src,
        'Future<bool> _startAudioIfRegistered()',
      );
      expect(start, contains('_audioMismatch('));
      expect(
        start.indexOf('_audioMismatch('),
        lessThan(start.indexOf('resolveMangaAudioSessionRequest')),
      );
      final String attach = _methodBody(src, 'void attachActiveAudio()');
      expect(attach, contains('_audioMismatch(driver.manifest)'));
      expect(
        attach.indexOf('_rejectStaleAudio'),
        lessThan(attach.indexOf('_attachAudio(driver)')),
      );
      final String reject = _methodBody(src, 'void _rejectStaleAudio(');
      expect(reject, contains('_detachAudio()'));
      expect(reject, contains('_session.stop()'));
      expect(reject, contains('clearHighlight()'));
      expect(reject, contains('_toastAudioMismatch(mismatch)'));
      expect(
        _methodBody(src, 'void _toastAudioMismatch('),
        contains('t.manga_audio_playback_ocr_stale'),
      );
    });

    test('播放中 OCR 落定 / 整卷完成 / 缓存补回都重新核对', () {
      expect(
        _methodBody(src, 'void _pageTextArrived('),
        contains('_recheckAudioAgainstOcr()'),
      );
      expect(
        _methodBody(src, 'void _volumeSettled('),
        contains('_recheckAudioAgainstOcr()'),
      );
      final String page = File(
        p.join(
          'lib',
          'src',
          'media',
          'manga',
          'reader',
          'manga_fushi_page.dart',
        ),
      ).readAsStringSync();
      final int recovered = page.indexOf(
        'setState(() => _payload = recoveredPayload);',
      );
      expect(recovered, greaterThanOrEqualTo(0));
      final int recheck = page.indexOf(
        '_readAloud._recheckAudioAgainstOcr()',
        recovered,
      );
      expect(recheck, greaterThan(recovered));
      // 紧跟在换 payload 之后（同一段，不是后面别处的调用）。
      expect(recheck - recovered, lessThan(200));
    });
  });
}

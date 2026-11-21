import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_mining.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:path/path.dart' as p;

MangaRenderedLine _line(
  String id, {
  required int page,
  required List<int> blocks,
  int durationMs = 1000,
  bool placeholder = false,
}) => MangaRenderedLine(
  lineId: id,
  page: page,
  blocks: blocks,
  speaker: 'A',
  kind: CastLineKind.spoken,
  beatMs: 0,
  file: '$id.m4a',
  durationMs: durationMs,
  text: id,
  placeholder: placeholder,
);

MokuroPayload _payload(String text, {int pages = 2}) => MokuroPayload(
  images: <MokuroImage>[
    for (int i = 0; i < pages; i++)
      MokuroImage(
        url: 'p$i.jpg',
        size: const MokuroSize(100, 100),
        blocks: <MokuroBlock>[
          for (int b = 0; b < 3; b++)
            MokuroBlock(
              rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
              isVertical: true,
              fontSize: 12,
              zIndex: 0,
              lines: <String>['$text$i$b'],
            ),
        ],
      ),
  ],
);

final List<MangaRenderedLine> _lines = <MangaRenderedLine>[
  _line('p0a', page: 0, blocks: <int>[0]),
  _line('p0b', page: 0, blocks: <int>[1, 2], durationMs: 1500),
  _line('p1ph', page: 1, blocks: <int>[0], placeholder: true),
  _line('p1b', page: 1, blocks: <int>[1]),
];

MangaAudioRegistration _registration(String? signature, {int pageCount = 2}) =>
    MangaAudioRegistration(
      bookKey: 'vol-1',
      manifestFile: File(p.join('root', 'vol-1', 'manifest.json')),
      manifest: MangaRenderManifest(
        pageCount: pageCount,
        lines: _lines,
        engineSignature: signature,
      ),
    );

void main() {
  group('mangaMiningAudioLineIndex', () {
    final MangaRenderManifest manifest = MangaRenderManifest(
      pageCount: 2,
      lines: _lines,
    );

    test('按页 + 块交集命中；交集最大者优先', () {
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 0, blocks: <int>[0]),
        0,
      );
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 0, blocks: <int>[2]),
        1,
      );
      // 句子分组横跨两句：块多的那句胜出。
      expect(
        mangaMiningAudioLineIndex(
          manifest,
          pageIndex: 0,
          blocks: <int>[0, 1, 2],
        ),
        1,
      );
    });

    test('别页同下标不算；占位静音行不算；空块 / 无交集返回 null', () {
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 1, blocks: <int>[2]),
        isNull,
      );
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 1, blocks: <int>[0]),
        isNull,
      );
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 1, blocks: <int>[1]),
        3,
      );
      expect(
        mangaMiningAudioLineIndex(manifest, pageIndex: 0, blocks: <int>[]),
        isNull,
      );
    });
  });

  group('resolveMangaMiningAudioClip', () {
    final MokuroPayload payload = _payload('a');
    final String signature = mangaPayloadOcrSignature(payload);

    test('签名一致且命中：取那一句的文件，区间带尾部留白、头部夹在 0', () {
      final MangaAudioRegistration registration = _registration(signature);
      final MangaMiningAudioClip? clip = resolveMangaMiningAudioClip(
        registration: registration,
        payload: payload,
        pageIndex: 0,
        blocks: <int>[1],
        headPadMs: 80,
        tailPadMs: 300,
      );
      expect(clip, isNotNull);
      expect(clip!.line.lineId, 'p0b');
      expect(clip.inputPath, p.normalize(p.join('root', 'vol-1', 'p0b.m4a')));
      expect(clip.range.audioFileIndex, 1);
      expect(clip.range.startMs, 0);
      // 每句独立一个文件，尾部留白不被相邻句夹住。
      expect(clip.range.endMs, 1800);
    });

    test('OCR 重跑过（签名不符）不取成品音频', () {
      expect(
        resolveMangaMiningAudioClip(
          registration: _registration(signature),
          payload: _payload('b'),
          pageIndex: 0,
          blocks: <int>[1],
        ),
        isNull,
      );
    });

    test('没记签名的旧清单只核页数；页数不符不取', () {
      expect(
        resolveMangaMiningAudioClip(
          registration: _registration(null),
          payload: _payload('b'),
          pageIndex: 0,
          blocks: <int>[0],
        )?.line.lineId,
        'p0a',
      );
      expect(
        resolveMangaMiningAudioClip(
          registration: _registration(null, pageCount: 3),
          payload: payload,
          pageIndex: 0,
          blocks: <int>[0],
        ),
        isNull,
      );
    });

    test('没登记 / 没命中返回 null（调用方不给句子音频，不做 TTS 兜底）', () {
      expect(
        resolveMangaMiningAudioClip(
          registration: null,
          payload: payload,
          pageIndex: 0,
          blocks: <int>[0],
        ),
        isNull,
      );
      expect(
        resolveMangaMiningAudioClip(
          registration: _registration(signature),
          payload: payload,
          pageIndex: 1,
          blocks: <int>[2],
        ),
        isNull,
      );
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/ocr/manga_ai_ocr_stream.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_geometry.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 大模型识别层套在整卷事件流上：本地结果先到（读者不用干等），同页补发一次
/// 重读后的结果；finished 把整卷改写落盘、交出新路径。失败保留本地结果。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ai_ocr_stream_');
    await File(
      '${dir.path}/p1.png',
    ).writeAsBytes(img.encodePng(img.Image(width: 200, height: 100)));
  });
  tearDown(() => dir.delete(recursive: true));

  MokuroImage localPage() => const MokuroImage(
    url: 'p1.png',
    size: MokuroSize(200, 100),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(10, 10, 50, 90),
        isVertical: true,
        fontSize: 20,
        zIndex: 0,
        lines: <String>['期限の悪い'],
        confidence: 0.3,
      ),
    ],
  );

  Future<String> writeResult() async {
    final File out = File('${dir.path}/manga_ocr_out/manga.json');
    await out.parent.create(recursive: true);
    await out.writeAsString(
      jsonEncode(
        mangaPayloadToJson(MokuroPayload(images: <MokuroImage>[localPage()])),
      ),
    );
    return out.path;
  }

  MangaAiOcrRefiner refiner(int status, String text) => MangaAiOcrRefiner(
    provider: AiProviderConfig(
      id: 'p',
      presetId: kAiCustomPresetId,
      name: 'p',
      baseUrl: Uri.parse('https://example.com/v1'),
      apiKey: 'k',
      model: 'm',
    ),
    mode: MangaAiOcrMode.lowConfidence,
    clientFactory: () => AiChatClient(
      client: MockClient(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'content': '{"blocks":[{"id":1,"text":"$text"}]}',
                },
              },
            ],
          }),
          status,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    ),
  );

  Stream<MangaOcrBackgroundEvent> source(String resultPath) =>
      Stream<MangaOcrBackgroundEvent>.fromIterable(<MangaOcrBackgroundEvent>[
        MangaOcrBackgroundEvent.progress(
          pagesDone: 1,
          pagesTotal: 1,
          pageIndex: 0,
          page: localPage(),
        ),
        MangaOcrBackgroundEvent.finished(
          pagesTotal: 1,
          resultPath: resultPath,
          external: false,
        ),
      ]);

  test('本地页先到、重读页补发、finished 落盘的是重读后的整卷', () async {
    final String resultPath = await writeResult();
    final List<MangaOcrBackgroundEvent> events =
        await refineMangaOcrEventsWithAi(
          source(resultPath),
          imageDirPath: dir.path,
          refiner: refiner(200, '機嫌の悪い'),
        ).toList();

    expect(events, hasLength(3));
    expect(events[0].page!.blocks.single.lines, <String>['期限の悪い']);
    expect(events[1].finished, isFalse);
    expect(events[1].pageIndex, 0);
    expect(events[1].page!.blocks.single.lines, <String>['機嫌の悪い']);
    expect(events[2].finished, isTrue);
    final MokuroPayload written = parseMangaJson(
      await File(events[2].resultPath!).readAsString(),
    );
    expect(written.images.single.blocks.single.lines, <String>['機嫌の悪い']);
    expect(written.images.single.blocks.single.aiRecognized, isTrue);
  });

  test('请求失败：只转发本地事件，整卷结果原样', () async {
    final String resultPath = await writeResult();
    final List<MangaOcrBackgroundEvent> events =
        await refineMangaOcrEventsWithAi(
          source(resultPath),
          imageDirPath: dir.path,
          refiner: refiner(500, 'x'),
        ).toList();
    expect(events, hasLength(2));
    expect(events.last.resultPath, resultPath);
    expect(
      parseMangaJson(
        await File(resultPath).readAsString(),
      ).images.single.blocks.single.lines,
      <String>['期限の悪い'],
    );
  });
}

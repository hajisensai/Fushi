import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 低置信度默认交给大模型（2026-10-13）：不出分引擎的可疑度判据 + 请求里带的
/// 上下文（本地猜测 / 附近文字 / 标题 / 语言 / 字幕版提示词）。
void main() {
  final AiProviderConfig provider = AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'vision',
  );

  MokuroBlock cue(String text, {double? confidence}) => MokuroBlock(
    rectangle: const MokuroRect.fromLTRB(0, 0, 600, 40),
    isVertical: false,
    fontSize: 30,
    zIndex: 0,
    lines: <String>[text],
    confidence: confidence,
  );

  MangaAiOcrCropRequest item(int seed, MokuroBlock block) =>
      MangaAiOcrCropRequest(
        crop: Uint8List.fromList(<int>[137, 80, 78, 71, seed]),
        block: block,
      );

  /// 记下每次请求的 messages，回复每张图 `新{编号}`。
  (AiChatClient Function(), List<List<Object?>>) capture() {
    final List<List<Object?>> requests = <List<Object?>>[];
    AiChatClient factory() => AiChatClient(
      client: MockClient((http.Request request) async {
        final Map<String, Object?> body =
            jsonDecode(request.body) as Map<String, Object?>;
        final List<Object?> messages = body['messages']! as List<Object?>;
        requests.add(messages);
        final Object? content =
            (messages.last! as Map<String, Object?>)['content'];
        final int count = (content! as List)
            .where((Object? part) => (part! as Map)['type'] == 'image_url')
            .length;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'content': jsonEncode(<String, Object?>{
                    'blocks': <Object?>[
                      for (int id = 1; id <= count; id++)
                        <String, Object?>{'id': id, 'text': '新$id'},
                    ],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    return (factory, requests);
  }

  String systemOf(List<Object?> messages) =>
      (messages.first! as Map<String, Object?>)['content']! as String;

  String userTextOf(List<Object?> messages) {
    final List<Object?> parts =
        (messages.last! as Map<String, Object?>)['content']! as List<Object?>;
    return parts
        .whereType<Map<String, Object?>>()
        .where((Map<String, Object?> part) => part['type'] == 'text')
        .map((Map<String, Object?> part) => part['text']! as String)
        .join('\n');
  }

  group('isSuspectMangaOcrText', () {
    test('乱码字符不论语言都可疑', () {
      expect(isSuspectMangaOcrText('あ�い'), isTrue);
      expect(isSuspectMangaOcrText('ab\u0001'), isTrue);
      expect(isSuspectMangaOcrText('私'), isTrue);
    });

    test('不知道语言时只看乱码', () {
      expect(isSuspectMangaOcrText('lorem ipsum'), isFalse);
      expect(isSuspectMangaOcrText('不明'), isFalse);
    });

    test('只有标点不算可疑（漫画里这类块本来就多）', () {
      expect(isSuspectMangaOcrText('！？', language: 'ja'), isFalse);
      expect(isSuspectMangaOcrText('…', language: 'ja'), isFalse);
    });

    test('中日文：整段拉丁字母、或拉丁字母夹在中日文之间', () {
      expect(isSuspectMangaOcrText('lI1l', language: 'ja'), isTrue);
      expect(isSuspectMangaOcrText('あいxう', language: 'ja'), isTrue);
      expect(isSuspectMangaOcrText('什么l东西', language: 'zh-Hans'), isTrue);
      expect(isSuspectMangaOcrText('今日はいい天気', language: 'ja'), isFalse);
      expect(
        isSuspectMangaOcrText('OKだよ', language: 'ja'),
        isFalse,
        reason: '外来词在句首、两侧不都是中日文',
      );
    });

    test('中日文里 ≤3 字母的大写 / 全角缩写不算可疑，小写或更长的仍算', () {
      expect(isSuspectMangaOcrText('OK', language: 'ja'), isFalse);
      expect(isSuspectMangaOcrText('ＮＧ！', language: 'ja'), isFalse);
      expect(isSuspectMangaOcrText('TV', language: 'zh'), isFalse);
      expect(isSuspectMangaOcrText('abc', language: 'ja'), isTrue);
      expect(isSuspectMangaOcrText('HELLO', language: 'ja'), isTrue);
    });

    test('韩文没有谚文却有拉丁字母；拉丁语言混进中日韩文字', () {
      expect(isSuspectMangaOcrText('Il0', language: 'ko'), isTrue);
      expect(isSuspectMangaOcrText('안녕하세요', language: 'ko'), isFalse);
      expect(isSuspectMangaOcrText('Hello あ', language: 'en'), isTrue);
      expect(isSuspectMangaOcrText("I can't do it", language: 'en'), isFalse);
    });
  });

  test('低置信度档：没分数的块按可疑度送，有分数的仍按门槛', () async {
    final (AiChatClient Function() factory, List<List<Object?>> requests) =
        capture();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.lowConfidence,
      context: const MangaAiOcrContext(language: 'ja'),
      clientFactory: factory,
    );
    final List<String?> texts = await refiner
        .refineCrops(<MangaAiOcrCropRequest>[
          item(1, cue('今日は')),
          item(2, cue('あいxう')),
          item(3, cue('元気', confidence: 0.99)),
          item(4, cue('期限', confidence: 0.4)),
        ]);
    expect(requests, hasLength(1));
    expect(texts, <String?>[null, '新1', null, '新2']);
  });

  test('请求带上本地猜测、附近文字、标题与语言；字幕用字幕版提示词', () async {
    final (AiChatClient Function() factory, List<List<Object?>> requests) =
        capture();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      context: const MangaAiOcrContext(
        source: MangaAiOcrSource.subtitle,
        title: '響け！',
        language: 'ja',
      ),
      clientFactory: factory,
    );
    await refiner.refineCrops(
      <MangaAiOcrCropRequest>[item(1, cue('一行目')), item(2, cue('二"行目'))],
      nearby: <String>['前の台詞', '  ', 'もう一つ'],
    );
    final List<Object?> messages = requests.single;
    expect(systemOf(messages), kSubtitleAiOcrSystemPrompt);
    final String user = userTextOf(messages);
    expect(user, contains('There are 2 images'));
    expect(user, contains('subtitle lines'));
    expect(user, contains('Work title: "響け！"'));
    expect(user, contains('Expected language: ja'));
    expect(user, contains('1: "一行目"'));
    expect(user, contains(r'2: "二\"行目"'), reason: '引号按 JSON 转义，不串行');
    expect(user, contains('"前の台詞"'));
    expect(user, contains('"もう一つ"'));
    expect(user, isNot(contains('""')), reason: '空白行不当附近文字');
  });

  test('附近文字只带最后几行、每行截断', () {
    final String user = buildMangaAiOcrUserPrompt(
      localGuesses: <String>['x'],
      nearby: <String>[
        for (int i = 0; i < kMangaAiOcrMaxNearbyLines + 3; i++) '行$i',
        'あ' * (kMangaAiOcrMaxNearbyLineLength + 20),
      ],
      context: const MangaAiOcrContext(),
    );
    expect(user, isNot(contains('"行0"')));
    expect(user, contains('"行${kMangaAiOcrMaxNearbyLines + 2}"'));
    expect(user, contains('"${'あ' * kMangaAiOcrMaxNearbyLineLength}"'));
    expect(user, isNot(contains('あ' * (kMangaAiOcrMaxNearbyLineLength + 1))));
  });

  test('漫画整页：没送的块当附近文字带上，默认漫画提示词', () async {
    final (AiChatClient Function() factory, List<List<Object?>> requests) =
        capture();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.lowConfidence,
      clientFactory: factory,
    );
    final MokuroImage page = MokuroImage(
      url: 'p.png',
      size: const MokuroSize(600, 200),
      blocks: <MokuroBlock>[
        cue('確かな字', confidence: 0.99),
        cue('怪しい', confidence: 0.1),
      ],
    );
    await refiner.refinePage(page, _whitePng());
    final List<Object?> messages = requests.single;
    expect(systemOf(messages), kMangaAiOcrSystemPrompt);
    final String user = userTextOf(messages);
    expect(user, contains('1: "怪しい"'));
    expect(user, contains('"確かな字"'));
  });
}

/// 600×200 的白色 PNG：refinePage 要真能解码出裁图。
Uint8List _whitePng() {
  final img.Image image = img.Image(width: 600, height: 200);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

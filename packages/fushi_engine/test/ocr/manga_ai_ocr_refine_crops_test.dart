import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 跨页批量重读（[MangaAiOcrRefiner.refineCrops]，字幕整轨用）与共享客户端。
/// 全部用 MockClient / 进程内假客户端，不打真网。
void main() {
  final AiProviderConfig provider = AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'vision',
  );

  /// 一条横排字幕的本地块：600×40、字号 30 → 框容量约 27 字。
  MokuroBlock cue(String text, {double? confidence, bool ai = false}) =>
      MokuroBlock(
        rectangle: const MokuroRect.fromLTRB(0, 0, 600, 40),
        isVertical: false,
        fontSize: 30,
        zIndex: 0,
        lines: <String>[text],
        confidence: confidence,
        aiRecognized: ai,
      );

  /// 每项一张不同字节的「裁图」（只是被 base64 发出去，不必是真 PNG）。
  MangaAiOcrCropRequest item(int seed, MokuroBlock block) =>
      MangaAiOcrCropRequest(
        crop: Uint8List.fromList(<int>[137, 80, 78, 71, seed, seed + 1]),
        block: block,
      );

  /// 回复按本批图片数逐个回 `第{请求序}-{编号}`；记下每次请求带了几张图与
  /// 工厂被调了几次。
  ({
    AiChatClient Function() factory,
    List<int> imagesPerRequest,
    List<int> factoryCalls,
  })
  fake({int status = 200, String Function(int call, int count)? reply}) {
    final List<int> imagesPerRequest = <int>[];
    final List<int> factoryCalls = <int>[0];
    int calls = 0;
    AiChatClient factory() {
      factoryCalls[0]++;
      // 重试退避不真等：sleep 推进假时钟，限频器与客户端共用（只给 sleep 空操作、
      // 时钟仍是真的，限频器醒来复查时刻会空转到真实时间过去）。重试语义本身在
      // ai_rate_limiter_test 里测。
      DateTime now = DateTime.utc(2026, 10, 13);
      DateTime clock() => now;
      return AiChatClient(
        clock: clock,
        rateLimiter: AiRateLimiter(
          now: clock,
          sleep: (Duration d) async => now = now.add(d),
        ),
        client: MockClient((http.Request request) async {
          final Map<String, Object?> body =
              jsonDecode(request.body) as Map<String, Object?>;
          final List<Object?> messages = body['messages']! as List<Object?>;
          final Object? content =
              (messages.last! as Map<String, Object?>)['content'];
          final int count = content is List
              ? content
                    .where(
                      (Object? part) => (part! as Map)['type'] == 'image_url',
                    )
                    .length
              : 0;
          imagesPerRequest.add(count);
          final int call = calls++;
          final String text =
              reply?.call(call, count) ??
              jsonEncode(<String, Object?>{
                'blocks': <Object?>[
                  for (int id = 1; id <= count; id++)
                    <String, Object?>{'id': id, 'text': '第$call-$id'},
                ],
              });
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': text},
                },
              ],
            }),
            status,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
    }

    return (
      factory: factory,
      imagesPerRequest: imagesPerRequest,
      factoryCalls: factoryCalls,
    );
  }

  test('按档位筛：低置信度才送，高分 / 不出分 / 已读过 / 空文字都交回 null', () async {
    final f = fake();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.lowConfidence,
      clientFactory: f.factory,
    );
    final List<String?> texts = await refiner
        .refineCrops(<MangaAiOcrCropRequest>[
          item(1, cue('期限', confidence: 0.4)),
          item(2, cue('元気', confidence: 0.99)),
          item(3, cue('不明')),
          item(4, cue('済み', confidence: 0.1, ai: true)),
          item(5, cue('  ', confidence: 0.1)),
          item(6, cue('機嫌', confidence: 0.2)),
        ]);
    expect(f.imagesPerRequest, <int>[2], reason: '只有两张低置信度的进了同一批');
    expect(texts, <String?>['第0-1', null, null, null, null, '第0-2']);
  });

  test('按 blocksPerRequest 打包，结果按原序对回', () async {
    final f = fake();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
      blocksPerRequest: 3,
    );
    final List<String?> texts = await refiner.refineCrops(
      <MangaAiOcrCropRequest>[
        for (int i = 0; i < 7; i++) item(i * 2, cue('字幕$i')),
      ],
    );
    expect(f.imagesPerRequest, <int>[3, 3, 1]);
    expect(texts, <String?>[
      '第0-1',
      '第0-2',
      '第0-3',
      '第1-1',
      '第1-2',
      '第1-3',
      '第2-1',
    ]);
  });

  test('缓存命中不发请求；新读到的写进缓存（按裁图 SHA-1 键）', () async {
    final Directory dir = await Directory.systemTemp.createTemp('ai_crops_');
    addTearDown(() => dir.delete(recursive: true));
    final MangaAiOcrCropRequest hit = item(1, cue('期限'));
    final MangaAiOcrCropRequest miss = item(9, cue('機嫌'));
    final MangaAiOcrCache cache = MangaAiOcrCache.forVolume(dir.path, provider);
    await cache.storeAll(<String, String>{
      sha1.convert(hit.crop).toString(): '既読',
    });

    final f = fake();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
    );
    expect(
      await refiner.refineCrops(<MangaAiOcrCropRequest>[hit], cache: cache),
      <String?>['既読'],
    );
    expect(f.imagesPerRequest, isEmpty, reason: '全部命中缓存时一个请求都不发');
    expect(f.factoryCalls.single, 0, reason: '不发请求就不建客户端');

    expect(
      await refiner.refineCrops(<MangaAiOcrCropRequest>[
        hit,
        miss,
      ], cache: cache),
      <String?>['既読', '第0-1'],
    );
    expect(f.imagesPerRequest, <int>[1], reason: '只有未命中的那张发出去');
    expect(
      await MangaAiOcrCache.forVolume(
        dir.path,
        provider,
      ).lookup(sha1.convert(miss.crop).toString()),
      '第0-1',
    );
  });

  test('校验不过（过长 / 空白 / 缺编号）的交回 null 且不进缓存', () async {
    final Directory dir = await Directory.systemTemp.createTemp('ai_crops_');
    addTearDown(() => dir.delete(recursive: true));
    final f = fake(
      reply: (_, _) =>
          '{"blocks":[{"id":1,"text":"${'長' * 200}"},{"id":2,"text":"  "},'
          '{"id":4,"text":"好"}]}',
    );
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
    );
    final MangaAiOcrCache cache = MangaAiOcrCache.forVolume(dir.path, provider);
    final List<MangaAiOcrCropRequest> items = <MangaAiOcrCropRequest>[
      item(1, cue('短い')),
      item(3, cue('空')),
      item(5, cue('三')),
      item(7, cue('四')),
    ];
    final List<String?> texts = await refiner.refineCrops(items, cache: cache);
    expect(texts, <String?>[null, null, null, '好']);
    for (int i = 0; i < 3; i++) {
      expect(
        await cache.lookup(sha1.convert(items[i].crop).toString()),
        isNull,
      );
    }
    expect(await cache.lookup(sha1.convert(items[3].crop).toString()), '好');
  });

  test('两次调用（含并发）共用同一个客户端；dispose 关掉它', () async {
    int created = 0;
    final List<_CountingChatClient> clients = <_CountingChatClient>[];
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: () {
        created++;
        final _CountingChatClient client = _CountingChatClient();
        clients.add(client);
        return client;
      },
    );
    await refiner.refineCrops(<MangaAiOcrCropRequest>[item(1, cue('一'))]);
    await Future.wait(<Future<List<String?>>>[
      refiner.refineCrops(<MangaAiOcrCropRequest>[item(3, cue('二'))]),
      refiner.refineCrops(<MangaAiOcrCropRequest>[item(5, cue('三'))]),
    ]);
    expect(created, 1, reason: '整个实例只建一个 AiChatClient');
    expect(clients.single.calls, 3);
    expect(clients.single.closed, isFalse);

    refiner.dispose();
    expect(clients.single.closed, isTrue);
    expect(refiner.isCancelled, isTrue);
    expect(
      await refiner.refineCrops(<MangaAiOcrCropRequest>[item(7, cue('四'))]),
      <String?>[null],
    );
    expect(created, 1, reason: 'dispose 之后不再建新客户端、不再发请求');
    expect(clients.single.calls, 3);
  });

  test('取消：在途请求被中止，结果全为 null；之后不再发请求', () async {
    final _GatedChatClient client = _GatedChatClient(
      '{"blocks":[{"id":1,"text":"機嫌"},{"id":2,"text":"元気"}]}',
    );
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: () => client,
    );
    final Future<List<String?>> running = refiner.refineCrops(
      <MangaAiOcrCropRequest>[item(1, cue('期限')), item(3, cue('元気'))],
    );
    await client.started.future;
    refiner.cancel();
    expect(await running, <String?>[null, null]);
    expect(client.closed, isTrue, reason: '取消要关掉共享客户端以中止在途请求');

    expect(
      await refiner.refineCrops(<MangaAiOcrCropRequest>[item(5, cue('三'))]),
      <String?>[null],
    );
    expect(client.calls, 1, reason: '取消后不再发请求');
  });

  test('致命失败（鉴权）后本次剩余批次与之后的调用都不再发请求', () async {
    final f = fake(status: 401);
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
      blocksPerRequest: 1,
    );
    final List<String?> first = await refiner.refineCrops(
      <MangaAiOcrCropRequest>[
        item(1, cue('一')),
        item(3, cue('二')),
        item(5, cue('三')),
      ],
    );
    expect(first, <String?>[null, null, null]);
    expect(f.imagesPerRequest, hasLength(1));
    expect(refiner.fatalFailure, 'unauthorized');

    expect(
      await refiner.refineCrops(<MangaAiOcrCropRequest>[item(7, cue('四'))]),
      <String?>[null],
    );
    expect(f.imagesPerRequest, hasLength(1));
  });

  test('瞬时失败（5xx）每批先重试满，用尽后只丢这一批，后面的批次照发', () async {
    final f = fake(status: 503);
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
      blocksPerRequest: 1,
    );
    await refiner.refineCrops(<MangaAiOcrCropRequest>[
      item(1, cue('一')),
      item(3, cue('二')),
    ]);
    expect(f.imagesPerRequest, <int>[
      for (int i = 0; i < 2 * kAiChatMaxAttempts; i++) 1,
    ]);
    expect(refiner.fatalFailure, isNull);
  });

  test('refinePage 与 refineCrops 混用也只建一个客户端，页结果照常落块', () async {
    final f = fake();
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
    );
    final Uint8List pageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 200, height: 100)),
    );
    MokuroImage page(String text) => MokuroImage(
      url: 'p.png',
      size: const MokuroSize(200, 100),
      blocks: <MokuroBlock>[
        MokuroBlock(
          rectangle: const MokuroRect.fromLTRB(10, 10, 50, 90),
          isVertical: true,
          fontSize: 20,
          zIndex: 0,
          lines: <String>[text],
        ),
      ],
    );
    final first = await refiner.refinePage(page('一'), pageBytes);
    await refiner.refineCrops(<MangaAiOcrCropRequest>[item(3, cue('二'))]);
    final second = await refiner.refinePage(page('三'), pageBytes);
    expect(f.factoryCalls.single, 1);
    expect(f.imagesPerRequest, <int>[1, 1, 1]);
    expect(first.page.blocks.single.lines.join(), '第0-1');
    expect(first.stats.replaced, 1);
    expect(second.page.blocks.single.lines.join(), '第2-1');
    expect(second.page.blocks.single.aiRecognized, isTrue);
  });

  // BUG-3314：一批多图按编号对回，模型把邻条的字答到这条的编号上（或照抄提示里的
  // 附近台词），字幕里相邻两条就成了同一句。台词取自《新・のび太の海底鬼岩城》PGS
  // 的真实本地识别结果。
  test('回复串号（答成同批别条 / 附近台词）不采用，本条留本地文字', () async {
    final f = fake(
      reply: (int call, int count) => jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          // 1 号答成了 2 号的台词，2 号正常（只纠了一个形近字），3 号照抄附近台词。
          <String, Object?>{'id': 1, 'text': '(のび太)キャンプ行くなら山がいい!'},
          <String, Object?>{'id': 2, 'text': '(のび太)キャンプ行くなら山がいい!'},
          <String, Object?>{'id': 3, 'text': 'しずかちゃんはどっち?'},
        ],
      }),
    );
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
    );
    final List<String?> texts = await refiner.refineCrops(
      <MangaAiOcrCropRequest>[
        item(1, cue('(スネ夫)のび太は泳げないからだろ?')),
        item(2, cue('(のび太)キャンプ行くなら山がいい！')),
        item(3, cue('緑に囲まれておいしい空気')),
      ],
      nearby: <String>['しずかちゃんはどっち?'],
    );
    expect(texts, <String?>[null, '(のび太)キャンプ行くなら山がいい!', null]);
  });

  test('归属判据：读错几个字仍算本条；同一句只差说话人时分不出、照收', () {
    expect(
      mangaAiOcrReplyBelongsToCrop(
        '鳥の声で起きる朝',
        local: 'とりこえおあさ鳥の声で起きる朝',
        batchmates: <String>['緑に囲まれておいしい空気'],
      ),
      isTrue,
    );
    expect(
      mangaAiOcrReplyBelongsToCrop(
        '(スタッフB)Aフレーム振り出しスロー',
        local: '(スタッフA)Aフレーム振り出しスロー',
        batchmates: <String>['(スタッフB)Aフレーム振り出しスロー'],
      ),
      isTrue,
    );
    expect(
      mangaAiOcrReplyBelongsToCrop(
        'やっぱり山だよね!',
        local: 'マリンアクティビティや色あざやかなサンゴや魚!',
        batchmates: <String>['やっぱり山だよね!'],
      ),
      isFalse,
    );
    // 真串号：差一个全半角标点仍是同一句，照样拒。
    expect(
      mangaAiOcrReplyBelongsToCrop(
        '(のび太)キャンプ行くなら山がいい!',
        local: '(スネ夫)のび太は泳げないからだろ?',
        batchmates: <String>['(のび太)キャンプ行くなら山がいい！'],
      ),
      isFalse,
    );
  });

  // 审查回归：送去重读的是本地低置信度块，本图相似度天生低；前后句近似（约 0.73）
  // 不是串号，正确回复不能被丢回糊掉的本地结果。
  test('归属判据：与同批 / 附近的近似句不算串号，只拦近乎相同或逐字照抄', () {
    expect(
      mangaAiOcrReplyBelongsToCrop(
        'そうなんだよ',
        local: 'ぞラなんたよ',
        batchmates: <String>['そうだよね'],
        nearby: <String>['そうだよね'],
      ),
      isTrue,
    );
    // 逐字照抄附近台词、而本地猜测并不像它：拒。
    expect(
      mangaAiOcrReplyBelongsToCrop(
        'しずかちゃんはどっち?',
        local: '緑に囲まれておいしい空気',
        nearby: <String>['しずかちゃんは どっち?'],
      ),
      isFalse,
    );
    // 台词本身重复一遍（本地也读出了同一句）：照收。
    expect(
      mangaAiOcrReplyBelongsToCrop(
        'はい!',
        local: 'はい!',
        nearby: <String>['はい!'],
      ),
      isTrue,
    );
  });

  test('refineCrops：近似的前句在附近台词 / 同批里时，本条的正确回复照收', () async {
    final f = fake(
      reply: (int call, int count) => jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          <String, Object?>{'id': 1, 'text': 'そうだよね'},
          <String, Object?>{'id': 2, 'text': 'そうなんだよ'},
        ],
      }),
    );
    final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
      provider: provider,
      mode: MangaAiOcrMode.all,
      clientFactory: f.factory,
    );
    final List<String?> texts = await refiner.refineCrops(
      <MangaAiOcrCropRequest>[item(1, cue('そうだよね')), item(2, cue('ぞラなんたよ'))],
      nearby: <String>['そうだよね'],
    );
    expect(texts, <String?>['そうだよね', 'そうなんだよ']);
  });
}

/// 立即回固定回复，记调用次数与是否被关。
class _CountingChatClient extends AiChatClient {
  int calls = 0;
  bool closed = false;

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    calls++;
    await Future<void>.delayed(Duration.zero);
    if (closed) throw const AiChatFailure('network_error');
    return '{"blocks":[{"id":1,"text":"読"}]}';
  }

  @override
  void close() {
    closed = true;
  }
}

/// 请求挂起直到 [close]（模拟真实客户端关闭时中止在途请求）。
class _GatedChatClient extends AiChatClient {
  _GatedChatClient(this.reply);

  final String reply;
  final Completer<void> started = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int calls = 0;
  bool closed = false;

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    calls += 1;
    if (!started.isCompleted) started.complete();
    await _gate.future;
    if (closed) throw const AiChatFailure('network_error');
    return reply;
  }

  @override
  void close() {
    closed = true;
    if (!_gate.isCompleted) _gate.complete();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-2493：iOS 上 AnkiMobile `infoForAdding` 往返回到 Fushi 后牌组/笔记类型不刷新。
// 此前整条回传链只有一个入口——`fushi://ankiFetch` 回调——它没送达（或到得比预期
// 晚）时没有任何兜底，设置页永远挂着「已打开 AnkiMobile，请去同意」；而开了
// 「制卡到已配对设备」后，`main.dart` 用 `is! AnkiMobileRepository` 判型直接 return，
// 回调即使送达也被静默丢弃。这里守往返状态机与解包。

const AnkiFetchResult _ok = AnkiFetchResult.success(
  decks: <AnkiDeck>[AnkiDeck(id: 0, name: 'Default')],
  noteTypes: <AnkiNoteType>[
    AnkiNoteType(id: 0, name: 'Basic', fields: <String>['Front']),
  ],
);

const AnkiFetchResult _notActive = AnkiFetchResult.error(
  'not active',
  code: AnkiErrorCode.ankiMobileNotActive,
);

class _CountingRead {
  _CountingRead(this.result);

  final AnkiFetchResult result;
  int calls = 0;

  Future<AnkiFetchResult> call() async {
    calls++;
    return result;
  }
}

/// 只为满足构造签名的假发送器：本文件不走制卡转发。
class _NoopMineSender implements RemoteMineSender {
  @override
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload) =>
      throw UnimplementedError();

  @override
  Future<RemoteDuplicateCheck> isDuplicate({
    required String expression,
    required String reading,
  }) =>
      throw UnimplementedError();

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName) =>
      throw UnimplementedError();

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) =>
      throw UnimplementedError();

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) =>
      throw UnimplementedError();

  @override
  Future<bool> probeMediaMaintenance() => throw UnimplementedError();

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({required bool dryRun}) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnkiMobileInfoReturnCoordinator', () {
    test('没发起过请求时，回到前台不读剪贴板', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator();
      final read = _CountingRead(_ok);

      final result = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );

      expect(result, isNull);
      expect(read.calls, 0);
    });

    test('x-success 没送达：回到前台就是往返终点，读一次并落地', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final read = _CountingRead(_ok);

      final result = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );

      expect(result, same(_ok));
      expect(read.calls, 1);
      expect(coordinator.awaitingReturn, isFalse);
    });

    test('同一次往返只读一次：URL 回调之后再回到前台不重读', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final read = _CountingRead(_ok);

      final first = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        read.call,
      );
      final second = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );

      expect(first, same(_ok));
      // 剪贴板取走即清空，第二次读必然是 empty——会把刚成功的结果盖成一条错误。
      expect(second, isNull);
      expect(read.calls, 1);
    });

    test('回到前台先读完了，随后到达的 URL 回调不重读', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final read = _CountingRead(_ok);

      await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );
      final late = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        read.call,
      );

      expect(late, isNull);
      expect(read.calls, 1);
    });

    test('读还在途中时，另一条路只能等，不并发再读', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final gate = Completer<AnkiFetchResult>();
      var calls = 0;

      final Future<AnkiFetchResult?> inFlight = coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        () {
          calls++;
          return gate.future;
        },
      );
      final Future<AnkiFetchResult?> concurrent = coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        () async {
          calls++;
          return _ok;
        },
      );

      expect(await concurrent, isNull);
      gate.complete(_ok);
      expect(await inFlight, same(_ok));
      expect(calls, 1);
    });

    test('冷启动（本进程没发起过请求）收到 URL 回调仍读一次，重复送达不再读', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator();
      final read = _CountingRead(_ok);

      final first = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        read.call,
      );
      final duplicate = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        read.call,
      );

      expect(first, same(_ok));
      expect(duplicate, isNull);
      expect(read.calls, 1);
    });

    test('notActive 不是终点：保留等待态，下次回到前台再读', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final timedOut = _CountingRead(_notActive);
      final read = _CountingRead(_ok);

      final first = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.urlCallback,
        timedOut.call,
      );
      expect(first, same(_notActive));
      expect(coordinator.awaitingReturn, isTrue);

      final retry = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );
      expect(retry, same(_ok));
      expect(read.calls, 1);
    });

    test('新一轮 fetch 重新打开等待态', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator()..markRequested();
      final read = _CountingRead(_ok);

      await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );
      coordinator.markRequested();
      final again = await coordinator.consume(
        AnkiMobileInfoReturnTrigger.appResumed,
        read.call,
      );

      expect(again, same(_ok));
      expect(read.calls, 2);
    });
  });

  group('AnkiMobileRepository 接入往返状态机', () {
    test('fetchConfiguration 打开 AnkiMobile 后，回到前台即可取回结果', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator();
      var reads = 0;
      final repo = AnkiMobileRepository(
        openUrl: (_) async => true,
        readInfoForAddingJson: () async {
          reads++;
          return const AnkiMobilePasteboardRead.ok(
            '{"decks":[{"name":"Default"}],'
            '"notetypes":[{"name":"Basic","fields":[{"name":"Front"}]}]}',
          );
        },
        infoReturnCoordinator: coordinator,
      );

      // 打开之前回到前台：无事可做。
      expect(
        await repo.consumeInfoForAddingReturn(
          AnkiMobileInfoReturnTrigger.appResumed,
        ),
        isNull,
      );

      final opened = await repo.fetchConfiguration();
      expect((opened as AnkiFetchError).code, AnkiErrorCode.ankiMobileOpened);
      expect(coordinator.awaitingReturn, isTrue);

      final result = await repo.consumeInfoForAddingReturn(
        AnkiMobileInfoReturnTrigger.appResumed,
      );
      expect(result, isA<AnkiFetchSuccess>());
      expect(reads, 1);

      // 紧随其后的 URL 回调不再读第二次。
      expect(
        await repo.consumeInfoForAddingReturn(
          AnkiMobileInfoReturnTrigger.urlCallback,
        ),
        isNull,
      );
      expect(reads, 1);
    });

    test('打不开 AnkiMobile 时不进入等待态', () async {
      final coordinator = AnkiMobileInfoReturnCoordinator();
      final repo = AnkiMobileRepository(
        openUrl: (_) async => false,
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
        infoReturnCoordinator: coordinator,
      );

      await repo.fetchConfiguration();

      expect(coordinator.awaitingReturn, isFalse);
    });
  });

  group('resolveAnkiMobileRepository', () {
    test('裸 AnkiMobileRepository 原样返回', () {
      final repo = AnkiMobileRepository(
        openUrl: (_) async => true,
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
        infoReturnCoordinator: AnkiMobileInfoReturnCoordinator(),
      );

      expect(resolveAnkiMobileRepository(repo), same(repo));
    });

    test('被「制卡到已配对设备」包裹时解包到本地仓库，而不是静默丢弃', () {
      final local = AnkiMobileRepository(
        openUrl: (_) async => true,
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
        infoReturnCoordinator: AnkiMobileInfoReturnCoordinator(),
      );
      final wrapped = RemoteMiningAnkiRepository(
        local: local,
        client: _NoopMineSender(),
      );

      expect(resolveAnkiMobileRepository(wrapped), same(local));
    });

    test('本地后端不是 AnkiMobile 时返回 null', () {
      final wrapped = RemoteMiningAnkiRepository(
        local: AnkiConnectRepository(),
        client: _NoopMineSender(),
      );

      expect(resolveAnkiMobileRepository(wrapped), isNull);
      expect(resolveAnkiMobileRepository(AnkiConnectRepository()), isNull);
    });
  });

  // main.dart 进不了单元测试的 widget 树（页面 build 需要整套 ProviderScope），
  // 源码守卫是这层唯一可落地的自动化：回传入口必须解包、必须挂到 resumed。
  group('main.dart 回传入口（源码守卫）', () {
    final String src = File('lib/main.dart').readAsStringSync();

    test('不再用 is! AnkiMobileRepository 判型丢弃回调', () {
      expect(src, isNot(contains('is! AnkiMobileRepository')));
      expect(src, contains('resolveAnkiMobileRepository('));
    });

    test('iOS 回到前台走 appResumed 兜底', () {
      const String anchor =
          'void didChangeAppLifecycleState(AppLifecycleState state)';
      final int start = src.indexOf(anchor);
      expect(start, greaterThan(-1), reason: '锚点漂移，守卫失效');
      final int end = src.indexOf('\n  }\n', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('AppLifecycleState.resumed'));
      expect(body, contains('AnkiMobileInfoReturnTrigger.appResumed'));
    });

    test('URL 回调与回到前台共用同一个去重入口', () {
      expect(src, contains('AnkiMobileInfoReturnTrigger.urlCallback'));
      expect(src, contains('consumeInfoForAddingReturn('));
      expect(src, isNot(contains('repo.consumeInfoForAddingPasteboard()')));
    });
  });
}

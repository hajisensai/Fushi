import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/sources/core_audio_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final AppLocale originalLocale = LocaleSettings.currentLocale;
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));
  tearDown(() => LocaleSettings.setLocale(originalLocale));

  test(
    'resource fetch failures explain network recovery before backend use',
    () {
      for (final Object error in <Object>[
        http.ClientException('HTTP 503', Uri.parse('https://source.test/file')),
        TimeoutException('request timed out'),
      ]) {
        final String message = discoveryTorrentResolveFailureMessage(error);
        expect(message, t.download_resource_resolve_failed);
        expect(message, isNot(contains('qBittorrent')));
        expect(message, isNot(contains('source.test')));
      }
    },
  );

  test(
    'invalid metainfo and ambiguous volume selection have distinct recovery',
    () {
      final String invalid = discoveryTorrentResolveFailureMessage(
        TorrentMetainfoException(
          TorrentMetainfoErrorCode.invalidBencode,
          'unexpected HTML response',
        ),
      );
      final String selection = discoveryTorrentResolveFailureMessage(
        const CoreAudioFileMatchException(
          'Multiple torrent files match volume',
        ),
      );
      expect(invalid, t.download_torrent_invalid);
      expect(selection, t.download_torrent_selection_failed);
      expect(selection, isNot(invalid));
      expect(invalid, isNot(contains('unexpected HTML')));
    },
  );

  test(
    'queued success does not promise automatic import or name a backend',
    () {
      expect(
        genericPushMessage(GenericPushOutcome.ok),
        t.discovery_download_queued,
      );
      expect(genericPushMessage(GenericPushOutcome.ok), isNot(contains('入库')));
      expect(
        genericPushMessage(GenericPushOutcome.ok),
        isNot(contains('qBittorrent')),
      );
      expect(
        genericPushMessage(GenericPushOutcome.pushFailed),
        t.download_request_failed,
      );
      expect(
        genericPushMessage(GenericPushOutcome.pushFailed),
        isNot(contains('qBittorrent')),
      );
    },
  );

  // 发现页「下载」与「AI 下载」共用 [startDiscoveryItemDownload] 一条路径（页面
  // 只维护「解析中」状态、把下载整个委托出去）。这里按行为钉住：解析阶段失败 →
  // 日志记 resolve 阶段 + 原始异常与栈、toast 给解析失败的恢复文案；入队阶段失败
  // → 日志记 enqueue 阶段 + 原始异常与栈、toast 给入队失败文案。两阶段不得混成
  // 同一种失败——阶段错了，用户拿到的恢复建议就是错的。
  group('startDiscoveryItemDownload failure stages', () {
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navigatorKey;
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('resolve failure keeps resolve stage and original error',
        (WidgetTester tester) async {
      final TorrentMetainfoException original = TorrentMetainfoException(
        TorrentMetainfoErrorCode.invalidBencode,
        'unexpected HTML response',
      );
      final _StageTestAppModel appModel = _StageTestAppModel(
        source: _ResolveThrowingSource(original),
      );
      final BuildContext context = await pumpHost(tester);
      final int before = ErrorLogService.instance.entries.length;

      final bool started = await startDiscoveryItemDownload(
        context: context,
        appModel: appModel,
        item: _torrentItem(payload: null),
      );
      await tester.pump();

      expect(started, isFalse);
      final List<ErrorLogEntry> logged =
          ErrorLogService.instance.entries.sublist(before);
      expect(logged, hasLength(1));
      expect(logged.single.source, 'DiscoveryTorrent.resolve.stage-src');
      expect(logged.single.error, original.toString());
      expect(logged.single.stackTrace, isNotEmpty);
      expect(find.text(t.download_torrent_invalid), findsOneWidget);
      expect(find.text(t.download_request_failed), findsNothing);

      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('enqueue failure keeps enqueue stage and original error',
        (WidgetTester tester) async {
      final StateError original = StateError('backend exploded');
      final _StageTestAppModel appModel = _StageTestAppModel(
        source: _ResolveThrowingSource(
          const FormatException('must not resolve'),
        ),
        enqueueError: original,
      );
      final BuildContext context = await pumpHost(tester);
      final int before = ErrorLogService.instance.entries.length;

      final bool started = await startDiscoveryItemDownload(
        context: context,
        appModel: appModel,
        item: _torrentItem(
          payload: const DiscoveryTorrentPayload(
            magnetUri:
                'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          ),
        ),
      );
      await tester.pump();

      expect(started, isFalse);
      final List<ErrorLogEntry> logged =
          ErrorLogService.instance.entries.sublist(before);
      expect(logged, hasLength(1));
      expect(logged.single.source, 'DiscoveryTorrent.enqueue.stage-src');
      expect(logged.single.error, original.toString());
      expect(logged.single.stackTrace, isNotEmpty);
      expect(find.text(t.download_request_failed), findsOneWidget);
      expect(find.text(t.download_resource_resolve_failed), findsNothing);

      await tester.pump(const Duration(seconds: 3));
    });
  });

  test('discovery page delegates downloads to the shared staged path', () {
    final String page = File(
      'lib/src/pages/implementations/media_discovery_page.dart',
    ).readAsStringSync();
    final int downloadStart = page.indexOf('Future<void> _download(');
    expect(downloadStart, isNonNegative);
    final String download = page.substring(
      downloadStart,
      page.indexOf('\n  }\n', downloadStart),
    );
    // 页面只管「解析中」状态；不得再自带一份会吞掉阶段信息的 catch。
    expect(download, contains('startDiscoveryItemDownload('));
    expect(download, isNot(contains('catch')));

    final String actions = File(
      'lib/src/pages/implementations/download_actions.dart',
    ).readAsStringSync();
    final String enqueue = actions.substring(
      actions.indexOf(
        'Future<GenericPushOutcome> enqueueSelectedDiscoveryTorrent',
      ),
      actions.indexOf('String genericPushMessage'),
    );
    expect(enqueue, contains('on Object catch (error, stack)'));
    expect(
      enqueue,
      contains(
        "ErrorLogService.instance.log('DiscoveryTorrent.enqueue', error, stack)",
      ),
    );
  });
}

DiscoveryResourceItem _torrentItem({required DiscoveryPayload? payload}) =>
    DiscoveryResourceItem(
      sourceId: 'stage-src',
      title: 'Stage test',
      id: 'item-1',
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.torrent,
      payload: payload,
    );

class _ResolveThrowingSource extends MediaDiscoverySource {
  _ResolveThrowingSource(this.error);

  final Exception error;

  @override
  String get id => 'stage-src';

  @override
  String get displayName => 'Stage source';

  @override
  int get priority => 0;

  @override
  DiscoveryCapabilities get capabilities =>
      DiscoveryCapabilities(kinds: DiscoveryMediaKind.values);

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) =>
      throw UnimplementedError();

  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    throw error;
  }
}

/// 只装配下载路径碰得到的两处：发现服务（找源）与偏好仓库——交给下载后端的
/// 第一步 `resolveDownloadExecution` 读 `prefsRepo`，在这里抛出即模拟「解析已
/// 成功、交接下载后端失败」。
class _StageTestAppModel extends AppModel {
  _StageTestAppModel({required MediaDiscoverySource source, this.enqueueError})
      : _service = MediaDiscoveryService(
          sources: <MediaDiscoverySource>[source],
        ),
        super(testPlatformServices());

  final MediaDiscoveryService _service;
  final Error? enqueueError;

  @override
  MediaDiscoveryService get mediaDiscoveryService => _service;

  @override
  PreferencesRepository get prefsRepo => throw enqueueError ??
      StateError('prefsRepo must not be reached before resolve succeeds');
}

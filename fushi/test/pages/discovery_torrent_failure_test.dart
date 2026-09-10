import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/sources/core_audio_discovery_source.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';

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

  test('production download catches preserve stage and original diagnostics',
      () {
    final String page = File(
      'lib/src/pages/implementations/media_discovery_page.dart',
    ).readAsStringSync();
    final String download = page.substring(
      page.indexOf('Future<void> _download('),
    );
    expect(download, contains('bool resolving = true;'));
    expect(
      download.indexOf('resolving = false;'),
      greaterThan(download.indexOf('await source.resolvePayload(item)')),
    );
    expect(download, contains('on Object catch (error, stack)'));
    expect(download, contains("resolving ? 'resolve' : 'enqueue'"));
    expect(
      download,
      matches(
        RegExp(r'ErrorLogService\.instance\.log\([\s\S]*?error,\s*stack,'),
      ),
    );
    expect(download, contains('discoveryTorrentResolveFailureMessage(error)'));

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

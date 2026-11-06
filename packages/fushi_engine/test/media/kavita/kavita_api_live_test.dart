// Opt-in, READ-ONLY live check against a real Kavita server.
//
// Skipped unless KAVITA_URL and KAVITA_KEY are set. It never writes progress,
// never marks anything read, and never prints the key or any authenticated URL.
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:test/test.dart';
import 'dart:io';

void main() {
  final String? url = Platform.environment['KAVITA_URL'];
  final String? key = Platform.environment['KAVITA_KEY'];
  final bool enabled =
      url != null && url.isNotEmpty && key != null && key.isNotEmpty;

  test(
    'live: authenticate, list libraries, read a series page and detail',
    () async {
      final KavitaApi api = KavitaApi(
        serverUrl: KavitaApi.normalizeServerUrl(url!),
        apiKey: key!,
      );
      addTearDown(api.close);
      await api.authenticate();
      final List<KavitaLibrary> libs = await api.getLibraries();
      expect(libs, isNotEmpty);
      final KavitaSeriesPage page = await api.getSeriesPage(pageSize: 5);
      expect(page.items, isNotEmpty);
      final KavitaSeriesDetail detail = await api.getSeriesDetail(
        page.items.first.id,
      );
      expect(detail.allChapters, isNotEmpty);
    },
    skip: enabled ? false : 'set KAVITA_URL and KAVITA_KEY to run',
  );
}

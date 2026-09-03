import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind;

/// TODO-2936 source-scan guard: the manga / game / browser media-type Profile
/// bindings must each have (1) a binding row in the settings UI and (2) a real
/// consumer that resolves & applies the binding — otherwise the new rows are
/// dead UI (the exact regression TODO-1063 fixed for `video`).
///
/// Consumers:
/// - manga  → MangaFushiPage applies the binding on open (book-level binding
///   included: the manga bookKey is the same Profile entryKey as for books).
/// - game   → every galgame hook session entry point (library/home launch,
///   texthooker launch + attach) applies the binding before starting.
/// - browser→ the yomitan-api server fires onLookupActivity on real lookup /
///   mine endpoints; AppModel forwards to a delegate injected by main.dart.
///
/// Also closes the gap that the enum could grow a value with no binding row:
/// the UI list is checked against `ProfileMediaKind.values` exhaustively.
/// Tests run with CWD = `fushi/`.
void main() {
  String read(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path missing');
    return f.readAsStringSync();
  }

  test('binding UI lists every ProfileMediaKind value (exhaustive)', () {
    final String src =
        read('lib/src/pages/implementations/profile_management_page.dart');
    for (final ProfileMediaKind kind in ProfileMediaKind.values) {
      expect(
        src.contains('ProfileMediaKind.${kind.name}'),
        isTrue,
        reason: 'binding row for "${kind.name}" missing from the media-type '
            'binding list — every enum value needs a row (TODO-2936)',
      );
    }
  });

  test('manga reader applies the manga media-type binding on open', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(
      src.contains('autoApplyBinding(') &&
          src.contains('mediaType: ProfileMediaKind.manga'),
      isTrue,
      reason: 'MangaFushiPage must call autoApplyBinding(mediaType: '
          'ProfileMediaKind.manga) on open, else the manga binding row is '
          'dead UI (TODO-2936)',
    );
  });

  test('every galgame hook session entry applies the game binding', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/galgame_home_page.dart',
      'lib/src/pages/implementations/games_library_page.dart',
      'lib/src/pages/implementations/texthooker_page.dart',
    ]) {
      final String src = read(path);
      expect(
        src.contains('autoApplyBinding(mediaType: ProfileMediaKind.game)'),
        isTrue,
        reason: '$path starts a gal hook session but never applies the '
            '"game" media-type Profile binding (TODO-2936)',
      );
    }
    // texthooker has TWO session entries (launch + attach) — both must apply.
    final String texthooker =
        read('lib/src/pages/implementations/texthooker_page.dart');
    expect(
      'autoApplyBinding(mediaType: ProfileMediaKind.game)'
          .allMatches(texthooker)
          .length,
      greaterThanOrEqualTo(2),
      reason: 'texthooker must apply the game binding on BOTH the launch and '
          'the attach-to-running-game entry (TODO-2936)',
    );
  });

  test('browser binding chain: server → AppModel → main.dart wiring', () {
    final String server = read('lib/src/sync/yomitan_api_server.dart');
    expect(
      server.contains('_kLookupActivityPaths') &&
          server.contains('_onLookupActivity?.call()'),
      isTrue,
      reason: 'yomitan-api server must fire onLookupActivity on lookup/mine '
          'endpoints (TODO-2936)',
    );
    // The SW-startup ping must NOT trigger a profile switch: a browser merely
    // being opened is not "the user is looking words up in the browser".
    expect(
      RegExp(r'_kLookupActivityPaths = <String>\{[^}]*extension/status')
          .hasMatch(server),
      isFalse,
      reason: '/api/extension/status is a liveness ping and must not be a '
          'lookup-activity trigger (TODO-2936)',
    );

    final String manager = read('lib/src/sync/yomitan_api_server_manager.dart');
    expect(
      manager.contains('onLookupActivity: _onLookupActivity'),
      isTrue,
      reason: 'manager must pass onLookupActivity through to the server',
    );

    final String appModel = read('lib/src/models/app_model.dart');
    expect(
      appModel.contains('onLookupActivity: _onBrowserLookupActivity') &&
          appModel.contains('browserLookupProfileApplier'),
      isTrue,
      reason: 'AppModel must forward lookup activity to the injected '
          'browser-profile applier delegate (TODO-2936)',
    );

    final String main = read('lib/main.dart');
    expect(
      main.contains('browserLookupProfileApplier') &&
          main.contains('mediaType: ProfileMediaKind.browser'),
      isTrue,
      reason: 'main.dart must inject the browser-profile applier '
          '(autoApplyBinding(mediaType: ProfileMediaKind.browser)) before '
          'initialise() (TODO-2936)',
    );
  });
}

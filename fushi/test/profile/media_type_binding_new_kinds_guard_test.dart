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
/// - browser→ (feedback biLEesNqWb) the yomitan-api server resolves every
///   profile-scoped extension request through `ExtensionProfileApi.resolveScope`
///   (extension pick > browser binding > follow app); the browser binding only
///   picks which read-only settings view serves the request and never switches
///   the app's active profile.
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
      // 判据拆成两段（与上面 manga 那条同形），**不**匹配整串调用字面量：
      // `autoApplyBinding` 的参数列表会增长（v99 加了 languageTag），一旦多一个
      // 具名参数或被 dart format 折行，整串字面量就再也匹配不上——那时守卫报的是
      // 「从没应用过绑定」，而真相是「调用还在，只是多了个参数」，把人引向完全
      // 错误的方向。两段式判据钉的是「这个文件确实调了它、且确实是 game 类型」，
      // 参数怎么长都不影响。
      expect(
        src.contains('autoApplyBinding(') &&
            src.contains('mediaType: ProfileMediaKind.game'),
        isTrue,
        reason: '$path starts a gal hook session but never applies the '
            '"game" media-type Profile binding (TODO-2936)',
      );
    }
    // texthooker has TWO session entries (launch + attach) — both must apply.
    final String texthooker =
        read('lib/src/pages/implementations/texthooker_page.dart');
    expect(
      'mediaType: ProfileMediaKind.game'.allMatches(texthooker).length,
      greaterThanOrEqualTo(2),
      reason: 'texthooker must apply the game binding on BOTH the launch and '
          'the attach-to-running-game entry (TODO-2936)',
    );
  });

  test('browser binding chain: server → adapter → main.dart wiring', () {
    final String server = read('lib/src/sync/fushi_api_server.dart');
    expect(
      server.contains('_kProfileScopedPaths') &&
          server.contains('profileApi.resolveScope('),
      isTrue,
      reason: 'yomitan-api server must resolve the profile scope on lookup / '
          'mine endpoints (biLEesNqWb / TODO-2936)',
    );
    // The SW-startup ping is not "the user is looking words up in the browser".
    expect(
      RegExp(r'_kProfileScopedPaths = <String>\{[^}]*extension/status')
          .hasMatch(server),
      isFalse,
      reason: '/api/extension/status is a liveness ping and must not be '
          'profile-scoped (TODO-2936)',
    );

    final String adapter = read('lib/src/profile/extension_profile_adapter.dart');
    expect(
      adapter.contains('mediaType: ProfileMediaKind.browser'),
      isTrue,
      reason: 'the extension profile adapter must honour the browser binding',
    );
    expect(
      RegExp(r'\b(applyProfile|switchProfile|setActiveProfile|autoApplyBinding)\(')
          .hasMatch(adapter),
      isFalse,
      reason: 'resolving an extension request must never switch the app '
          'profile (biLEesNqWb)',
    );

    final String main = read('lib/main.dart');
    expect(
      main.contains('appModel.browserExtensionProfileApi = AppExtensionProfileApi('),
      isTrue,
      reason: 'main.dart must inject the extension profile adapter before '
          'initialise()',
    );
    expect(
      main.contains('mediaType: ProfileMediaKind.browser'),
      isFalse,
      reason: 'main.dart must not auto-apply the browser binding to the app '
          '(biLEesNqWb: it only scopes extension requests)',
    );
  });
}

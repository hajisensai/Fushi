import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';

/// Pieces of the tracking plugin settings UI tests: an in-memory engine
/// (no FFI: the real engine runs its work in isolates, which `testWidgets`'
/// fake clock does not drive) and a fake site answering `login` / `account`
/// like the JS fake in `tracking_plugin_test_support.dart`.

/// The fake site behind every runtime: a pasted-token form sign-in.
///
/// Token `bad`: the site says no (a `pending` step with the plugin's
/// message). Empty token: `failed`. Anything else signs in as `user-<token>`.
final class FakeTrackingSite {
  String? token;

  /// Whether `begin` returns an `appUrl`.
  bool offerAppUrl = true;

  /// Sign-in methods offered (`login {op: methods}`).
  List<Map<String, Object?>> methods = <Map<String, Object?>>[
    <String, Object?>{'id': 'token', 'type': 'form', 'label': 'Paste a token'},
  ];

  final List<Map<String, Object?>> loginCalls = <Map<String, Object?>>[];

  static Map<String, Object?> _form(String session, String? message) =>
      <String, Object?>{
        'state': 'pending',
        'session': session,
        'message': ?message,
        'form': <String, Object?>{
          'fields': <Object?>[
            <String, Object?>{
              'id': 'token',
              'label': 'Token',
              'secret': true,
              'placeholder': 'abc',
            },
            <String, Object?>{
              'id': 'note',
              'label': 'Note',
              'multiline': true,
              'value': 'hello',
            },
          ],
          'actions': <Object?>[
            <String, Object?>{'id': 'ok', 'label': 'Sign in', 'primary': true},
            <String, Object?>{'id': 'help', 'label': 'Help'},
          ],
        },
      };

  Object? invoke(String method, Map<String, Object?> args) {
    switch (method) {
      case 'account':
        return token == null
            ? <String, Object?>{'loggedIn': false}
            : <String, Object?>{'loggedIn': true, 'name': 'user-$token'};
      case 'login':
        loginCalls.add(Map<String, Object?>.of(args));
        switch (args['op']) {
          case 'methods':
            return <String, Object?>{'methods': methods};
          case 'begin':
            return <String, Object?>{
              ..._form('s1', 'Paste the token from your profile'),
              if (offerAppUrl) 'appUrl': 'https://api.example.org/token',
            };
          case 'submit':
            final Object? inputs = args['inputs'];
            final String typed = inputs is Map ? '${inputs['token']}' : '';
            if (typed.isEmpty) {
              return <String, Object?>{
                'state': 'failed',
                'message': 'Empty token',
              };
            }
            if (typed == 'bad') return _form('s2', 'Token rejected by site');
            token = typed;
            return <String, Object?>{'state': 'done'};
          case 'logout':
            token = null;
            return null;
        }
    }
    throw StateError('unexpected call $method');
  }
}

/// An engine over plain files: a "package" is a key registered with
/// [package]; installing writes `<root>/<id>/.pkg` with its digest, and
/// verifying reads it back (a folder without it fails verification).
final class FakeTrackingPluginEngine implements TrackingPluginEngine {
  final Map<String, TrackingPluginInfo> _byDigest =
      <String, TrackingPluginInfo>{};
  final Map<String, FakeTrackingSite> sites = <String, FakeTrackingSite>{};
  final List<String> installs = <String>[];
  final List<String> cleared = <String>[];
  int _packages = 0;

  /// The site of plugin [id] (created on first use).
  FakeTrackingSite siteOf(String id) =>
      sites.putIfAbsent(id, FakeTrackingSite.new);

  /// Registers a package with [manifest] and returns its bytes.
  Uint8List package(Map<String, Object?> manifest, {String? signer}) {
    final String digest = 'digest-${++_packages}';
    _byDigest[digest] = TrackingPluginInfo.fromSummary(<String, Object?>{
      'manifest': manifest,
      'digest': digest,
      'signer': ?signer,
    }, trustedSigners: const <String>{});
    return Uint8List.fromList(utf8.encode(digest));
  }

  TrackingPluginInfo _lookup(String digest) {
    final TrackingPluginInfo? info = _byDigest[digest.trim()];
    if (info == null) {
      throw const TrackingPluginException(
        TrackingPluginErrorCode.invalidPackage,
        'files do not match',
      );
    }
    return info;
  }

  @override
  bool get isSupported => true;

  @override
  Future<TrackingPluginInfo> inspect(Uint8List zip) async =>
      _lookup(utf8.decode(zip, allowMalformed: true));

  @override
  Future<TrackingPluginInfo> install(
    Uint8List zip,
    String rootDir,
    String digest,
  ) async {
    final TrackingPluginInfo info = _lookup(utf8.decode(zip));
    if (info.digest != digest) {
      throw const TrackingPluginException(
        TrackingPluginErrorCode.invalidPackage,
        'digest changed',
      );
    }
    final Directory dir = Directory('$rootDir/${info.id}')
      ..createSync(recursive: true);
    File('${dir.path}/.pkg').writeAsStringSync(info.digest);
    installs.add(info.id);
    return info;
  }

  @override
  Future<TrackingPluginInfo> verify(String dir) async {
    final File file = File('$dir/.pkg');
    if (!file.existsSync()) {
      throw const TrackingPluginException(
        TrackingPluginErrorCode.unusable,
        'files do not match',
      );
    }
    return _lookup(file.readAsStringSync());
  }

  @override
  Future<void> clearCredentials(String rootDir, String pluginId) async {
    cleared.add(pluginId);
    sites.remove(pluginId);
  }

  @override
  Future<TrackingPluginRuntime> open({
    required String dir,
    required String rootDir,
    required File storageFile,
    required TrackingRateGate rateGate,
  }) async {
    final TrackingPluginInfo info = await verify(dir);
    return _FakeRuntime(info, siteOf(info.id));
  }
}

final class _FakeRuntime implements TrackingPluginRuntime {
  _FakeRuntime(this.info, this._site);

  @override
  final TrackingPluginInfo info;
  final FakeTrackingSite _site;
  bool _alive = true;

  @override
  bool get isAlive => _alive;

  @override
  bool allowsUrl(String url) =>
      info.networkDomains.contains(Uri.parse(url).host);

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async =>
      _site.invoke(method, args);

  @override
  Future<void> close() async => _alive = false;
}

/// Progress indicators the section and dialogs show while a call runs.
final Finder _progress = find.byWidgetPredicate(
  (Widget widget) =>
      widget is FushiLinearProgressIndicator ||
      widget is FushiCircularProgressIndicator,
);

/// Lets real file I/O (the manager's state file) finish between frames: each
/// I/O step completes in real time and continues on the next frame. Runs at
/// least [minRounds] rounds and until no progress indicator is left, then
/// settles the animations.
Future<void> settle(WidgetTester tester, {int minRounds = 12}) async {
  for (int round = 0; round < 200; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (round >= minRounds && _progress.evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

/// Drives [future] (started inside the test's fake zone) to completion.
///
/// Futures created by widgets under `testWidgets` only progress while the
/// test pumps; awaiting them after the body (in `tearDown`) never returns.
Future<void> drive(WidgetTester tester, Future<void> future) async {
  bool done = false;
  (Object, StackTrace)? failure;
  unawaited(
    future.then<void>(
      (_) => done = true,
      onError: (Object error, StackTrace stack) {
        failure = (error, stack);
        done = true;
      },
    ),
  );
  for (int round = 0; round < 200 && !done; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'the future did not complete');
  if (failure case (final Object error, final StackTrace stack)) {
    Error.throwWithStackTrace(error, stack);
  }
}

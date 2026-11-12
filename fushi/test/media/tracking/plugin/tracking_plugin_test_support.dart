import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';

/// Shared pieces of the tracking plugin host tests: a small fake-site plugin
/// packaged in memory, and an engine wrapper that records what the plugin
/// was asked.

const String fakePluginId = 'moe.test.tracking.fake';
const String fakeSiteId = 'fakesite';

Map<String, Object?> fakeManifest({
  String id = fakePluginId,
  String siteId = fakeSiteId,
  String name = 'Fake Site',
  String version = '0.1.0',
  String kind = 'tracking',
  List<String> kinds = const <String>['anime', 'manga', 'novel'],
  List<String> capabilities = const <String>[
    'login',
    'account',
    'trackingEntry',
    'trackingSubject',
    'trackingSearch',
    'trackingLookup',
  ],
  int requestsPerMinute = 30,
}) => <String, Object?>{
  'schema': 1,
  if (kind != 'music') 'kind': kind,
  'id': id,
  'name': name,
  'version': version,
  'api': 1,
  'entry': 'main.js',
  'capabilities': capabilities,
  'permissions': <String>['network', 'storage', 'credentials'],
  'network': <String, Object?>{
    'domains': <String>['api.example.org'],
    'methods': <String>['GET', 'POST'],
  },
  if (kind == 'tracking')
    'tracking': <String, Object?>{
      'siteId': siteId,
      'siteHost': 'example.org',
      'kinds': kinds,
      'defaultKinds': kinds,
      'modes': <String>['episode', 'chapter', 'volume'],
      'requestsPerMinute': requestsPerMinute,
    },
};

/// The fake site: entries in `fushi.storage`, a pasted-token form login in
/// `fushi.credentials`, lookups by `mal` and by another site's id `other`.
/// Subject ids 401 / 429 / 404 / 500 throw the matching error; subject 5
/// was merged into 6 (asking for 5 returns subject 6).
const String fakeSiteJs = r'''
const SUBJECTS = {
  1: { id: 1, name: 'Anime One', kind: 'anime', totalEpisodes: 12, linkedIds: { mal: 100 } },
  2: { id: 2, name: 'Manga Two', kind: 'manga', totalChapters: 50, finalVolume: 5, finished: true, titles: ['Zwei'] },
  3: { id: 3, name: 'Novel Three', kind: 'novel', totalChapters: 30, finished: false },
  4: { id: 4, name: '   ', kind: 'manga' },
  5: { id: 6, name: 'Merged into six', kind: 'manga', totalChapters: 20 },
  8: { id: -5, name: 'Negative', kind: 'manga' },
  7: { id: 7, name: 'Odd kind', kind: 'game' },
};
const FAIL = {
  401: 'unauthorized: token expired',
  429: 'rate_limited: slow down',
  404: 'not_found: no such subject',
  500: 'server exploded',
};
async function entries() {
  const raw = await fushi.storage.get('entries');
  return raw ? JSON.parse(raw) : {};
}
async function requireToken() {
  if (!(await fushi.credentials.get('token'))) throw new Error('unauthorized: sign in');
}
module.exports = {
  async login(a) {
    if (a.op === 'methods') {
      return { methods: [
        { id: 'token', type: 'form', label: 'Paste a token' },
        { id: 'qr', type: 'qr', label: 'Scan' },
      ] };
    }
    if (a.op === 'begin') {
      return {
        state: 'pending',
        session: 's1',
        appUrl: 'https://api.example.org/settings/token',
        form: {
          fields: [{ id: 'token', label: 'Token', secret: true, placeholder: 'abc' }],
          actions: [{ id: 'ok', label: 'Sign in', primary: true }],
        },
      };
    }
    if (a.op === 'submit') {
      if (!a.inputs.token) return { state: 'failed', message: 'Empty token' };
      await fushi.credentials.set('token', a.inputs.token);
      return { state: 'done' };
    }
    if (a.op === 'logout') {
      await fushi.credentials.remove('token');
      return null;
    }
    return null;
  },
  async account() {
    const t = await fushi.credentials.get('token');
    return t ? { loggedIn: true, name: 'user-' + t, avatar: 'ignored' } : { loggedIn: false };
  },
  async trackingSubject(a) {
    if (FAIL[a.id]) throw new Error(FAIL[a.id]);
    return SUBJECTS[a.id] || null;
  },
  async trackingEntry(a) {
    await requireToken();
    const all = await entries();
    if (a.op === 'get') return all[a.id] || null;
    const e = all[a.id] || {};
    for (const k of ['status', 'progress', 'progressVolume']) {
      if (a[k] !== undefined) e[k] = a[k];
    }
    all[a.id] = e;
    await fushi.storage.set('entries', JSON.stringify(all));
    return null;
  },
  async trackingSearch(a) {
    await fushi.http.request({ url: 'https://api.example.org/search?q=' + encodeURIComponent(a.query) });
    return { items: Object.values(SUBJECTS).filter((s) => s.kind === a.kind || s.kind === 'game') };
  },
  async trackingLookup(a) {
    if (a.idType === 'mal') return { items: a.id === 100 ? [SUBJECTS[1]] : [] };
    if (a.idType === 'other') {
      if (a.id === 9) return { items: [SUBJECTS[3], SUBJECTS[4]] };
      if (a.id === 10) return { items: [SUBJECTS[2], SUBJECTS[3]] };
    }
    return { items: [] };
  },
};
''';

/// A `.fushiplug` zip with `files.json` covering every file.
Uint8List buildPluginZip(
  Map<String, Object?> manifest, {
  String js = fakeSiteJs,
}) {
  final Map<String, List<int>> files = <String, List<int>>{
    'manifest.json': utf8.encode(jsonEncode(manifest)),
    'main.js': utf8.encode(js),
  };
  final Archive archive = Archive();
  for (final MapEntry<String, List<int>> e in files.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final List<int> listing = utf8.encode(
    jsonEncode(<String, Object?>{
      'files': <String, String>{
        for (final MapEntry<String, List<int>> e in files.entries)
          e.key: sha256.convert(e.value).toString(),
      },
    }),
  );
  archive.addFile(ArchiveFile('files.json', listing.length, listing));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Windows: the native library keeps the key (DPAPI). Elsewhere a fixed key.
final Future<Uint8List?> Function()? testVaultKey = Platform.isWindows
    ? null
    : () async => Uint8List.fromList(List<int>.filled(32, 7));

/// One capability call the plugin received.
typedef PluginCall = ({String method, Map<String, Object?> args});

/// Wraps an engine: records every capability call, counts HTTP requests and
/// lets a test pretend a package is signed ([signerOf] by digest; the test
/// packages are unsigned).
final class RecordingEngine implements TrackingPluginEngine {
  RecordingEngine(this.inner);

  /// The real engine with the network leg answered locally.
  factory RecordingEngine.real() {
    late final RecordingEngine engine;
    engine = RecordingEngine(
      SharedTrackingPluginEngine(
        httpClientFactory: HttpClient.new,
        log: (String id, String level, String message) {},
        vaultKey: testVaultKey,
        httpSend: (Map<String, Object?> request) async {
          engine.httpRequests.add(request);
          return <String, Object?>{
            'status': 200,
            'url': request['url'],
            'headers': <String, String>{},
            'setCookies': <String>[],
            'body': Uint8List.fromList(utf8.encode('{}')),
          };
        },
      ),
    );
    return engine;
  }

  final TrackingPluginEngine inner;
  final List<PluginCall> calls = <PluginCall>[];
  final List<Map<String, Object?>> httpRequests = <Map<String, Object?>>[];
  final Map<String, String> signerOf = <String, String>{};
  int opened = 0;

  /// Calls of [method] (and, for `trackingEntry`, of [op]).
  List<Map<String, Object?>> argsOf(String method, {String? op}) =>
      <Map<String, Object?>>[
        for (final PluginCall call in calls)
          if (call.method == method && (op == null || call.args['op'] == op))
            call.args,
      ];

  TrackingPluginInfo _sign(TrackingPluginInfo info) {
    final String? signer = signerOf[info.digest];
    if (signer == null) return info;
    return TrackingPluginInfo(
      id: info.id,
      kind: info.kind,
      name: info.name,
      version: info.version,
      capabilities: info.capabilities,
      permissions: info.permissions,
      networkDomains: info.networkDomains,
      digest: info.digest,
      signer: signer,
      trustedSigner: false,
      site: info.site,
    );
  }

  @override
  bool get isSupported => inner.isSupported;

  @override
  Future<TrackingPluginInfo> inspect(Uint8List zip) async =>
      _sign(await inner.inspect(zip));

  @override
  Future<TrackingPluginInfo> install(
    Uint8List zip,
    String rootDir,
    String digest,
  ) async => _sign(await inner.install(zip, rootDir, digest));

  @override
  Future<TrackingPluginInfo> verify(String dir) async =>
      _sign(await inner.verify(dir));

  @override
  Future<void> clearCredentials(String rootDir, String pluginId) =>
      inner.clearCredentials(rootDir, pluginId);

  @override
  Future<TrackingPluginRuntime> open({
    required String dir,
    required String rootDir,
    required File storageFile,
    required TrackingRateGate rateGate,
  }) async {
    opened++;
    return _RecordingRuntime(
      await inner.open(
        dir: dir,
        rootDir: rootDir,
        storageFile: storageFile,
        rateGate: rateGate,
      ),
      calls,
    );
  }
}

final class _RecordingRuntime implements TrackingPluginRuntime {
  _RecordingRuntime(this._inner, this._calls);

  final TrackingPluginRuntime _inner;
  final List<PluginCall> _calls;

  @override
  TrackingPluginInfo get info => _inner.info;

  @override
  bool get isAlive => _inner.isAlive;

  @override
  bool allowsUrl(String url) => _inner.allowsUrl(url);

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) {
    _calls.add((method: method, args: Map<String, Object?>.of(args)));
    return _inner.invoke(method, args);
  }

  @override
  Future<void> close() => _inner.close();
}

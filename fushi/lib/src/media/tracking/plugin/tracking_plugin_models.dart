/// Data the tracking plugin host works with: the installed package summary,
/// the site a plugin describes, errors with stable codes for the UI, and the
/// sign-in shapes the host renders (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §2, §3).
///
/// Everything here comes from untrusted plugin data and is parsed tolerantly:
/// a field of the wrong type counts as missing.
library;

import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

/// Stable error codes the UI translates. The English [TrackingPluginException]
/// message is for logs only.
enum TrackingPluginErrorCode {
  /// The platform has no plugin engine.
  unsupported('unsupported'),

  /// The package is broken, tampered with, or its digest does not match.
  invalidPackage('invalid_package'),

  /// The package is a plugin of another kind (a music plugin).
  notTrackingPlugin('not_tracking_plugin'),

  /// The plugin is not installed (or is being removed).
  notInstalled('not_installed'),

  /// The user switched the plugin off.
  disabled('disabled'),

  /// The installed files fail verification, or the manifest is unusable.
  unusable('unusable'),

  /// Another enabled plugin already serves the same site id.
  siteConflict('site_conflict'),

  /// The plugin does not declare the capability needed for the call.
  missingCapability('missing_capability'),

  /// The plugin says the sign-in is no longer valid (`unauthorized:`), or this
  /// device is not signed in.
  unauthorized('unauthorized'),

  /// The site asked to slow down (`rate_limited:`).
  rateLimited('rate_limited'),

  /// The subject does not exist on the site (`not_found:`).
  notFound('not_found'),

  /// The site has the subject as another kind than the link says.
  kindMismatch('kind_mismatch'),

  /// The plugin threw any other error (temporary).
  pluginError('plugin_error'),

  /// The plugin returned something of the wrong shape.
  badResult('bad_result'),

  /// The call did not finish in time.
  timeout('timeout'),

  /// The plugin runtime stopped (CPU budget exceeded, closed); reopened on the
  /// next use.
  runtimeStopped('runtime_stopped'),

  /// Clearing or reading the credential vault failed.
  credentials('credentials'),

  /// The package claims a site id that is reserved ([kReservedTrackingSiteIds]):
  /// only the package built into this app may serve it.
  reservedSite('reserved_site'),

  /// The plugin is built into the app: it can be turned off, not removed.
  builtIn('built_in');

  const TrackingPluginErrorCode(this.wire);

  /// The stable string the UI keys its translation on.
  final String wire;
}

/// A tracking plugin failure with a stable [code]. [message] is English (or,
/// for [TrackingPluginErrorCode.pluginError] and the prefixed codes, the text
/// the plugin gave after its prefix) and is never translated.
final class TrackingPluginException implements Exception {
  const TrackingPluginException(this.code, this.message, {this.pluginId});

  final TrackingPluginErrorCode code;
  final String message;
  final String? pluginId;

  @override
  String toString() =>
      'TrackingPluginException(${code.wire}, ${pluginId ?? '?'}): $message';
}

/// The exception for an error a plugin threw: `unauthorized:`, `rate_limited:`
/// and `not_found:` prefixes (spec §3) pick the code, the rest of the text is
/// the message. Anything else is [TrackingPluginErrorCode.pluginError].
TrackingPluginException trackingPluginErrorFromMessage(
  String message, {
  String? pluginId,
}) {
  final String trimmed = message.trim();
  for (final (String prefix, TrackingPluginErrorCode code)
      in <(String, TrackingPluginErrorCode)>[
        ('unauthorized:', TrackingPluginErrorCode.unauthorized),
        ('rate_limited:', TrackingPluginErrorCode.rateLimited),
        ('not_found:', TrackingPluginErrorCode.notFound),
      ]) {
    if (trimmed.startsWith(prefix)) {
      return TrackingPluginException(
        code,
        trimmed.substring(prefix.length).trim(),
        pluginId: pluginId,
      );
    }
  }
  return TrackingPluginException(
    TrackingPluginErrorCode.pluginError,
    trimmed,
    pluginId: pluginId,
  );
}

/// Capability names of a tracking plugin (spec §2).
abstract final class TrackingPluginCapability {
  static const String login = 'login';
  static const String account = 'account';
  static const String entry = 'trackingEntry';
  static const String subject = 'trackingSubject';
  static const String search = 'trackingSearch';
  static const String lookup = 'trackingLookup';

  /// The user's list by status (optional, read only; "View all watched").
  static const String list = 'trackingList';
}

/// Longest display text kept from plugin data (spec §4).
const int _maxText = 500;

String? _text(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > _maxText ? trimmed.substring(0, _maxText) : trimmed;
}

List<String> _strings(Object? value) => <String>[
  if (value is List)
    for (final Object? item in value)
      if (item is String) item,
];

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map<String, Object?>(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      )
    : const <String, Object?>{};

int? _int(Object? value) => switch (value) {
  final int whole => whole,
  final double real when real.isFinite && real == real.truncateToDouble() =>
    real.toInt(),
  _ => null,
};

/// The `tracking` section of a manifest: the site a plugin serves.
final class TrackingPluginSite {
  const TrackingPluginSite({
    required this.siteId,
    required this.siteHost,
    required this.kinds,
    required this.defaultKinds,
    required this.modes,
    required this.requestsPerMinute,
    this.subjectUrls = const <TrackingKind, String>{},
  });

  /// Same rule as the engine's manifest check.
  static final RegExp _siteIdPattern = RegExp(r'^[a-z0-9]{2,32}$');

  /// Parses the section; null when a required part is missing or invalid
  /// (the engine already validated it, so this only guards the shape).
  static TrackingPluginSite? tryParse(Object? json) {
    final Map<String, Object?> j = _map(json);
    final Object? siteId = j['siteId'];
    final Object? siteHost = j['siteHost'];
    final int? rate = _int(j['requestsPerMinute']);
    if (siteId is! String || !_siteIdPattern.hasMatch(siteId)) return null;
    if (siteHost is! String || siteHost.trim().isEmpty) return null;
    if (rate == null || rate < 1 || rate > 600) return null;
    final Set<TrackingKind> kinds = _kinds(j['kinds']);
    final Set<TrackingProgressMode> modes = <TrackingProgressMode>{
      for (final String raw in _strings(j['modes']))
        ...switch (raw) {
          'episode' => <TrackingProgressMode>[TrackingProgressMode.episode],
          'chapter' => <TrackingProgressMode>[TrackingProgressMode.chapter],
          'volume' => <TrackingProgressMode>[TrackingProgressMode.volume],
          'status' => <TrackingProgressMode>[TrackingProgressMode.status],
          _ => const <TrackingProgressMode>[],
        },
    };
    if (kinds.isEmpty || modes.isEmpty) return null;
    return TrackingPluginSite(
      siteId: siteId,
      siteHost: siteHost.trim(),
      kinds: Set<TrackingKind>.unmodifiable(kinds),
      defaultKinds: Set<TrackingKind>.unmodifiable(
        _kinds(j['defaultKinds']).intersection(kinds),
      ),
      modes: Set<TrackingProgressMode>.unmodifiable(modes),
      requestsPerMinute: rate,
      subjectUrls: _subjectUrlsOf(j['subjectUrl'], siteHost.trim()),
    );
  }

  /// `tracking.subjectUrl` is one template for every kind, or an object of
  /// one template per kind (a kind it leaves out has no page address).
  static Map<TrackingKind, String> _subjectUrlsOf(
    Object? value,
    String siteHost,
  ) {
    final Map<TrackingKind, String> out = <TrackingKind, String>{};
    if (value is String) {
      final String? template = _subjectUrlOf(value, siteHost);
      if (template != null) {
        for (final TrackingKind kind in TrackingKind.values) {
          out[kind] = template;
        }
      }
    } else if (value is Map) {
      for (final TrackingKind kind in TrackingKind.values) {
        final String? template = _subjectUrlOf(value[kind.value], siteHost);
        if (template != null) out[kind] = template;
      }
    }
    return Map<TrackingKind, String>.unmodifiable(out);
  }

  /// The engine checked the template; this keeps only a shape the host can
  /// fill safely (https, host = [siteHost] or a subdomain, `{id}` present).
  static String? _subjectUrlOf(Object? value, String siteHost) {
    if (value is! String || !value.contains('{id}')) return null;
    final Uri? uri = Uri.tryParse(
      value.replaceAll('{id}', '1').replaceAll('{kind}', 'anime'),
    );
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host != siteHost && !uri.host.endsWith('.$siteHost')) return null;
    return value;
  }

  static Set<TrackingKind> _kinds(Object? json) => <TrackingKind>{
    for (final String raw in _strings(json))
      ...switch (raw) {
        'anime' => <TrackingKind>[TrackingKind.anime],
        'manga' => <TrackingKind>[TrackingKind.manga],
        'novel' => <TrackingKind>[TrackingKind.novel],
        'game' => <TrackingKind>[TrackingKind.game],
        _ => const <TrackingKind>[],
      },
  };

  /// Provider id stored with links (`media_tracking_mappings.provider`).
  final String siteId;

  /// Host of the site's pages, used to recognize a pasted link.
  final String siteHost;
  final Set<TrackingKind> kinds;

  /// Kinds switched on until the user changes the switch.
  final Set<TrackingKind> defaultKinds;
  final Set<TrackingProgressMode> modes;

  /// HTTP budget the host enforces on the plugin.
  final int requestsPerMinute;

  /// Template of a subject's web page per kind (`{id}`, optional `{kind}`);
  /// a kind without one has no page address.
  final Map<TrackingKind, String> subjectUrls;

  /// The web page of subject [subjectId] of [kind], from [subjectUrls].
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) {
    final String? template = subjectUrls[kind];
    if (template == null || subjectId <= 0) return null;
    return Uri.tryParse(
      template
          .replaceAll('{id}', '$subjectId')
          .replaceAll('{kind}', kind.value),
    );
  }
}

/// What the user confirms before installing, and what the settings page shows
/// for an installed plugin.
final class TrackingPluginInfo {
  const TrackingPluginInfo({
    required this.id,
    required this.kind,
    required this.name,
    required this.version,
    required this.capabilities,
    required this.permissions,
    required this.networkDomains,
    required this.digest,
    required this.signer,
    required this.trustedSigner,
    required this.site,
    this.author,
    this.description,
    this.homepage,
  });

  /// Manifest `kind` of a tracking plugin.
  static const String trackingKind = 'tracking';

  /// Parses the engine's package summary (`{manifest, digest, signer}`).
  /// [trustedSigners] are the public keys shown as verified. Throws
  /// [TrackingPluginException] ([TrackingPluginErrorCode.invalidPackage])
  /// when the summary lacks an id, name, version or digest.
  factory TrackingPluginInfo.fromSummary(
    Map<String, Object?> summary, {
    required Set<String> trustedSigners,
  }) {
    final Map<String, Object?> manifest = _map(summary['manifest']);
    final Object? id = manifest['id'];
    final Object? name = manifest['name'];
    final Object? version = manifest['version'];
    final Object? digest = summary['digest'];
    if (id is! String || name is! String || version is! String) {
      throw const TrackingPluginException(
        TrackingPluginErrorCode.invalidPackage,
        'package summary has no id, name or version',
      );
    }
    if (digest is! String || digest.isEmpty) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.invalidPackage,
        'package summary has no digest',
        pluginId: id,
      );
    }
    final Object? signer = summary['signer'];
    final String? signerKey = signer is String && signer.isNotEmpty
        ? signer
        : null;
    final Object? kind = manifest['kind'];
    return TrackingPluginInfo(
      id: id,
      kind: kind is String && kind.isNotEmpty ? kind : 'music',
      name: _text(name) ?? id,
      version: version,
      author: _text(manifest['author']),
      description: _text(manifest['description']),
      homepage: _text(manifest['homepage']),
      capabilities: List<String>.unmodifiable(
        _strings(manifest['capabilities']),
      ),
      permissions: List<String>.unmodifiable(_strings(manifest['permissions'])),
      networkDomains: List<String>.unmodifiable(
        _strings(_map(manifest['network'])['domains']),
      ),
      digest: digest,
      signer: signerKey,
      trustedSigner: signerKey != null && trustedSigners.contains(signerKey),
      site: TrackingPluginSite.tryParse(manifest['tracking']),
    );
  }

  final String id;

  /// Manifest kind; only [trackingKind] packages are installed here.
  final String kind;
  final String name;
  final String version;
  final String? author;
  final String? description;
  final String? homepage;
  final List<String> capabilities;
  final List<String> permissions;
  final List<String> networkDomains;

  /// sha256 of `files.json`: what the user confirms.
  final String digest;

  /// Signing public key (base64); null = unsigned.
  final String? signer;

  /// [signer] is one of the keys the app trusts.
  final bool trustedSigner;

  /// The site; null when the manifest's `tracking` section is unusable.
  final TrackingPluginSite? site;

  bool get isTracking => kind == trackingKind;

  bool can(String capability) => capabilities.contains(capability);
}

/// Site ids a side-loaded plugin can never take: `bangumi` belongs to the
/// Bangumi plugin built into the app, `mal` names the MyAnimeList id space in
/// lookups. The engine rejects `mal`; `bangumi` is accepted by the manager
/// only from the package whose digest the app pinned at start
/// ([TrackingPluginManager.ensureBundled]; spec
/// docs/specs/2026-11-11-bangumi-bundled-plugin.md §3).
const Set<String> kReservedTrackingSiteIds = <String>{'bangumi', 'mal'};

/// One installed plugin as the manager lists it.
final class InstalledTrackingPlugin {
  const InstalledTrackingPlugin({
    required this.id,
    required this.enabled,
    this.info,
    this.error,
    this.conflictsWith,
    this.reservedSite = false,
    this.builtIn = false,
    this.included = false,
  });

  final String id;
  final bool enabled;

  /// Null when the installed files fail verification ([error] says why).
  final TrackingPluginInfo? info;
  final String? error;

  /// Id of the enabled plugin that serves the same site and was kept instead
  /// of this one (spec §2: the second is not registered).
  final String? conflictsWith;

  /// The site id is reserved ([kReservedTrackingSiteIds]) and this is not the
  /// package built into the app: never registered.
  final bool reservedSite;

  /// The exact package bundled with this app build (id and digest pinned at
  /// start): shown as built in, can be turned off but not removed.
  final bool builtIn;

  /// Exactly the removable package bundled with this app under this id
  /// (AniList, MangaBaka): shown as included with Fushi, can be turned off
  /// and removed. Its site id is not reserved.
  final bool included;

  /// Verified and has a usable site description.
  bool get valid => info != null && info!.site != null && info!.isTracking;

  /// Enabled, valid and not shadowed by another plugin of the same site:
  /// registered as a tracking provider.
  bool get registered =>
      enabled && valid && conflictsWith == null && !reservedSite;
}

/// The per-device sign-in state of one plugin (kept by the manager, never
/// synced).
final class TrackingPluginAccount {
  const TrackingPluginAccount({required this.loggedIn, this.name});

  static const TrackingPluginAccount signedOut = TrackingPluginAccount(
    loggedIn: false,
  );

  /// Parses the plugin's `account` result; anything but `loggedIn: true` is
  /// signed out.
  factory TrackingPluginAccount.fromJson(Object? json) {
    final Map<String, Object?> j = _map(json);
    if (j['loggedIn'] != true) return signedOut;
    return TrackingPluginAccount(loggedIn: true, name: _text(j['name']));
  }

  final bool loggedIn;
  final String? name;

  Map<String, Object?> toJson() => <String, Object?>{
    'loggedIn': loggedIn,
    if (name != null) 'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is TrackingPluginAccount &&
      other.loggedIn == loggedIn &&
      other.name == name;

  @override
  int get hashCode => Object.hash(loggedIn, name);
}

/// A sign-in method the host can render. v1 renders only `form` methods.
final class TrackingPluginLoginMethod {
  const TrackingPluginLoginMethod({
    required this.id,
    required this.label,
    this.description,
  });

  /// Parses `login {op: 'methods'}`; methods of any type but `form` are left
  /// out, as are entries without an id or label.
  static List<TrackingPluginLoginMethod> listFrom(Object? json) {
    final Object? methods = _map(json)['methods'];
    if (methods is! List) return const <TrackingPluginLoginMethod>[];
    return List<TrackingPluginLoginMethod>.unmodifiable(
      <TrackingPluginLoginMethod>[
        for (final Object? raw in methods)
          if (_map(raw) case final Map<String, Object?> m
              when m['type'] == 'form' &&
                  m['id'] is String &&
                  (m['id']! as String).isNotEmpty &&
                  _text(m['label']) != null)
            TrackingPluginLoginMethod(
              id: m['id']! as String,
              label: _text(m['label'])!,
              description: _text(m['description']),
            ),
      ],
    );
  }

  final String id;
  final String label;
  final String? description;
}

/// A text field of a `form` sign-in step.
final class TrackingPluginLoginField {
  const TrackingPluginLoginField({
    required this.id,
    required this.label,
    this.secret = false,
    this.multiline = false,
    this.placeholder,
    this.value,
  });

  final String id;
  final String label;

  /// Rendered obscured (a token or password).
  final bool secret;
  final bool multiline;
  final String? placeholder;

  /// Prefilled text.
  final String? value;
}

/// A button of a `form` sign-in step; its [id] goes back with `submit`.
final class TrackingPluginLoginAction {
  const TrackingPluginLoginAction({
    required this.id,
    required this.label,
    this.primary = false,
  });

  final String id;
  final String label;
  final bool primary;
}

enum TrackingPluginLoginState { pending, done, failed }

/// One step of a sign-in (`begin` / `submit` result).
final class TrackingPluginLoginChallenge {
  const TrackingPluginLoginChallenge({
    required this.state,
    this.session,
    this.message,
    this.appUrl,
    this.fields = const <TrackingPluginLoginField>[],
    this.actions = const <TrackingPluginLoginAction>[],
    this.account,
  });

  /// Parses a step. [allowAppUrl] decides whether the plugin's `appUrl` is
  /// kept (the host only shows https links inside the network grant).
  factory TrackingPluginLoginChallenge.fromJson(
    Object? json, {
    required bool Function(String url) allowAppUrl,
  }) {
    final Map<String, Object?> j = _map(json);
    final Map<String, Object?> form = _map(j['form']);
    final TrackingPluginLoginState state = switch (j['state']) {
      'done' => TrackingPluginLoginState.done,
      'failed' => TrackingPluginLoginState.failed,
      _ => TrackingPluginLoginState.pending,
    };
    final Object? rawSession = j['session'];
    final Object? rawAppUrl = j['appUrl'];
    String? appUrl;
    if (rawAppUrl is String) {
      final Uri? uri = Uri.tryParse(rawAppUrl.trim());
      if (uri != null && uri.scheme == 'https' && allowAppUrl(uri.toString())) {
        appUrl = uri.toString();
      }
    }
    final Object? rawFields = form['fields'];
    final Object? rawActions = form['actions'];
    return TrackingPluginLoginChallenge(
      state: state,
      session: rawSession is String && rawSession.isNotEmpty
          ? rawSession
          : null,
      message: _text(j['message']),
      appUrl: appUrl,
      fields: List<TrackingPluginLoginField>.unmodifiable(
        <TrackingPluginLoginField>[
          if (rawFields is List)
            for (final Object? raw in rawFields)
              if (_map(raw) case final Map<String, Object?> f
                  when f['id'] is String && _text(f['label']) != null)
                TrackingPluginLoginField(
                  id: f['id']! as String,
                  label: _text(f['label'])!,
                  secret: f['secret'] == true,
                  multiline: f['multiline'] == true,
                  placeholder: _text(f['placeholder']),
                  value: _text(f['value']),
                ),
        ],
      ),
      actions: List<TrackingPluginLoginAction>.unmodifiable(
        <TrackingPluginLoginAction>[
          if (rawActions is List)
            for (final Object? raw in rawActions)
              if (_map(raw) case final Map<String, Object?> a
                  when a['id'] is String && _text(a['label']) != null)
                TrackingPluginLoginAction(
                  id: a['id']! as String,
                  label: _text(a['label'])!,
                  primary: a['primary'] == true,
                ),
        ],
      ),
      account: j['account'] == null
          ? null
          : TrackingPluginAccount.fromJson(j['account']),
    );
  }

  final TrackingPluginLoginState state;

  /// Opaque value the plugin wants back with the next `submit`.
  final String? session;

  /// Text to show (plugin-provided, not translated).
  final String? message;

  /// "Open site" link: https and inside the plugin's network grant.
  final String? appUrl;
  final List<TrackingPluginLoginField> fields;
  final List<TrackingPluginLoginAction> actions;

  /// Account the plugin reported with a `done` step, if any.
  final TrackingPluginAccount? account;
}

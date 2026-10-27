import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';

/// 扩展 `chrome.storage.local` 在 app 内浏览器里的落点：一个设备本地偏好（JSON 对象），
/// 不进备份 / 同步（与浏览器其它设备本地键同列，见 `web_browser_prefs.dart`）。
const String kWebBrowserExtensionStoragePref = 'web_browser_extension_storage';

/// 有 app 真源的扩展键：读写直接落到 app 偏好，不另存一份（两边各存一份迟早分岔）。
typedef WebBrowserExtensionBridgedKey = ({
  Object? Function() read,
  Future<void> Function(Object? value) write,
});

/// 一次变更（`chrome.storage.onChanged` 的 `{oldValue, newValue}`；键被删时没有 newValue）。
typedef WebBrowserExtensionStorageChange = ({
  bool hadOld,
  Object? oldValue,
  bool hasNew,
  Object? newValue,
});

/// 把变更集编码成 `chrome.storage.onChanged` 的形状。
Map<String, Object?> webBrowserExtensionChangesJson(
  Map<String, WebBrowserExtensionStorageChange> changes,
) => <String, Object?>{
  for (final MapEntry<String, WebBrowserExtensionStorageChange> e
      in changes.entries)
    e.key: <String, Object?>{
      if (e.value.hadOld) 'oldValue': e.value.oldValue,
      if (e.value.hasNew) 'newValue': e.value.newValue,
    },
};

/// 扩展存储的 app 实现。
///
/// - 普通键：存在 [kWebBrowserExtensionStoragePref] 的 JSON 里；
/// - [bridged]：有 app 真源的键（如「查词时暂停」↔ `pause_on_lookup`），读写都走真源；
/// - [computed]：只读、现场算的键（如 `appLocale` = app 当前界面语言）。扩展写它们一律忽略
///   ——扩展里它们本就是 background 镜像 app 状态写进去的，宿主里直接现算。
class WebBrowserExtensionStorage {
  WebBrowserExtensionStorage({
    required PrefStore prefs,
    Map<String, WebBrowserExtensionBridgedKey> bridged =
        const <String, WebBrowserExtensionBridgedKey>{},
    Map<String, Object? Function()> computed =
        const <String, Object? Function()>{},
  }) : _prefs = prefs,
       _bridged = bridged,
       _computed = computed;

  final PrefStore _prefs;
  final Map<String, WebBrowserExtensionBridgedKey> _bridged;
  final Map<String, Object? Function()> _computed;

  /// 写操作串行队尾。`set` 在「读 JSON → 改 → 写回」中间要 await 真源键的写入，
  /// 两次写交错时后写回的那份会用旧快照盖掉先写的键（多标签页同时写、页内连发
  /// set 都会撞上）；整段读改写排队执行，每次都基于上一次写完的结果。
  Future<void> _writeTail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final Future<T> result = _writeTail.then((_) => op());
    _writeTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Map<String, Object?> _readStored() {
    final Object? raw = _prefs.getPref(
      kWebBrowserExtensionStoragePref,
      defaultValue: '',
    );
    if (raw is! String || raw.isEmpty) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, Object?>.of(decoded);
      }
    } on FormatException {
      // 坏数据：当空存储，下次写入覆盖。
    }
    return <String, Object?>{};
  }

  Future<void> _writeStored(Map<String, Object?> values) =>
      _prefs.setPref(kWebBrowserExtensionStoragePref, jsonEncode(values));

  bool _has(String key, Map<String, Object?> stored) =>
      _computed.containsKey(key) ||
      (_bridged.containsKey(key) && _bridged[key]!.read() != null) ||
      stored.containsKey(key);

  Object? _value(String key, Map<String, Object?> stored) {
    final Object? Function()? computed = _computed[key];
    if (computed != null) return computed();
    final WebBrowserExtensionBridgedKey? bridged = _bridged[key];
    if (bridged != null) return bridged.read();
    return stored[key];
  }

  /// `get(null)` = 全部键；否则只回存在的那些（缺的键不出现，与 chrome 同语义）。
  Map<String, Object?> get(List<String>? keys) {
    final Map<String, Object?> stored = _readStored();
    final Iterable<String> wanted =
        keys ?? <String>{...stored.keys, ..._bridged.keys, ..._computed.keys};
    final Map<String, Object?> out = <String, Object?>{};
    for (final String key in wanted) {
      if (!_has(key, stored)) continue;
      final Object? v = _value(key, stored);
      if (v == null && !stored.containsKey(key)) continue;
      out[key] = v;
    }
    return out;
  }

  /// 写入；回实际变化了的键（值没变的不报，与 chrome 同语义）。
  Future<Map<String, WebBrowserExtensionStorageChange>> set(
    Map<String, Object?> items,
  ) => _serialized(() => _set(items));

  Future<Map<String, WebBrowserExtensionStorageChange>> _set(
    Map<String, Object?> items,
  ) async {
    final Map<String, Object?> stored = _readStored();
    final Map<String, WebBrowserExtensionStorageChange> changes =
        <String, WebBrowserExtensionStorageChange>{};
    bool storedDirty = false;
    for (final MapEntry<String, Object?> e in items.entries) {
      if (_computed.containsKey(e.key)) continue;
      final bool hadOld = _has(e.key, stored);
      final Object? old = hadOld ? _value(e.key, stored) : null;
      if (hadOld && _jsonEquals(old, e.value)) continue;
      final WebBrowserExtensionBridgedKey? bridged = _bridged[e.key];
      if (bridged != null) {
        await bridged.write(e.value);
      } else {
        stored[e.key] = e.value;
        storedDirty = true;
      }
      changes[e.key] = (
        hadOld: hadOld,
        oldValue: old,
        hasNew: true,
        newValue: e.value,
      );
    }
    if (storedDirty) await _writeStored(stored);
    return changes;
  }

  /// 删键。真源键不能「删」（app 偏好总有值）——忽略。
  Future<Map<String, WebBrowserExtensionStorageChange>> remove(
    List<String> keys,
  ) => _serialized(() => _remove(keys));

  Future<Map<String, WebBrowserExtensionStorageChange>> _remove(
    List<String> keys,
  ) async {
    final Map<String, Object?> stored = _readStored();
    final Map<String, WebBrowserExtensionStorageChange> changes =
        <String, WebBrowserExtensionStorageChange>{};
    for (final String key in keys) {
      if (!stored.containsKey(key) ||
          _bridged.containsKey(key) ||
          _computed.containsKey(key)) {
        continue;
      }
      changes[key] = (
        hadOld: true,
        oldValue: stored.remove(key),
        hasNew: false,
        newValue: null,
      );
    }
    if (changes.isNotEmpty) await _writeStored(stored);
    return changes;
  }

  /// 外部（app 设置页）改了真源键：编出对应的变更集，好广播给页面。
  Map<String, WebBrowserExtensionStorageChange> snapshotOf(List<String> keys) {
    final Map<String, Object?> stored = _readStored();
    return <String, WebBrowserExtensionStorageChange>{
      for (final String key in keys)
        key: (
          hadOld: false,
          oldValue: null,
          hasNew: true,
          newValue: _value(key, stored),
        ),
    };
  }
}

bool _jsonEquals(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// 「跟随 Fushi」调色板要的 app 配色镜像（扩展里由 background.js 从查词响应镜像进
/// `appThemeMirror`）：同一份键清单（background.js `APP_THEME_MIRROR_KEYS`）。
const List<String> kWebBrowserExtensionThemeMirrorKeys = <String>[
  '--text-color',
  '--background-color',
  '--md-primary',
  '--md-on-primary',
  '--md-surface-container',
  '--md-surface-container-high',
  '--md-on-surface',
  '--md-on-surface-variant',
  '--md-outline-variant',
  '--md-primary-container',
  '--md-on-primary-container',
  '--md-secondary-container',
  '--md-on-secondary-container',
  '--md-tertiary',
  '--md-on-tertiary',
  '--md-tertiary-container',
  '--md-on-tertiary-container',
  '--md-surface-container-highest',
  '--md-error',
  '--md-surface',
  '--md-surface-container-lowest',
  '--md-surface-container-low',
  '--md-outline',
  '--md-inverse-surface',
  '--md-inverse-on-surface',
  '--md-inverse-primary',
  '--md-secondary',
  '--md-on-secondary',
  '--md-on-error',
  '--md-error-container',
  '--md-on-error-container',
  '--fushi-theme-seed',
  '--fushi-theme-variant',
  '--fushi-theme-neutral',
  '--fushi-pure-black',
  '--fushi-theme-system',
  '--fushi-theme-palette-id',
];

/// 现算 `appThemeMirror`：`{light: {...}, dark: {...}, current}`。
Map<String, Object?> webBrowserExtensionThemeMirror({
  required Map<String, String> Function(String scheme) colors,
  required bool dark,
}) {
  Map<String, String> pick(String scheme) {
    final Map<String, String> all = colors(scheme);
    return <String, String>{
      for (final String k in kWebBrowserExtensionThemeMirrorKeys)
        if (all[k] case final String v when v.isNotEmpty) k: v,
    };
  }

  return <String, Object?>{
    'light': pick('light'),
    'dark': pick('dark'),
    'current': dark ? 'dark' : 'light',
  };
}

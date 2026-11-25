/// Typed reads of a module snapshot / command args (JSON maps from the other
/// engine). Missing or mistyped values read as the fallback, so a panel never
/// throws on a snapshot from an older / newer main engine. Pure Dart.
extension CompanionSnapshotRead on Map<String, Object?> {
  String str(String key, [String fallback = '']) {
    final Object? v = this[key];
    return v is String ? v : fallback;
  }

  /// Null when missing or empty.
  String? strOrNull(String key) {
    final Object? v = this[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  int integer(String key, [int fallback = 0]) {
    final Object? v = this[key];
    return v is num ? v.toInt() : fallback;
  }

  int? intOrNull(String key) {
    final Object? v = this[key];
    return v is num ? v.toInt() : null;
  }

  double? doubleOrNull(String key) {
    final Object? v = this[key];
    return v is num ? v.toDouble() : null;
  }

  bool flag(String key) => this[key] == true;

  /// The list of maps under [key] (non-map items dropped).
  List<Map<String, Object?>> maps(String key) {
    final Object? raw = this[key];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? e in raw)
        if (e is Map)
          <String, Object?>{
            for (final MapEntry<Object?, Object?> kv in e.entries)
              if (kv.key is String) kv.key! as String: kv.value,
          },
    ];
  }

  /// The string list under [key] (non-strings dropped).
  List<String> strings(String key) {
    final Object? raw = this[key];
    if (raw is! List) return const <String>[];
    return <String>[
      for (final Object? e in raw)
        if (e is String) e,
    ];
  }

  /// The map under [key]; null when missing.
  Map<String, Object?>? mapOrNull(String key) {
    final Object? raw = this[key];
    if (raw is! Map) return null;
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> kv in raw.entries)
        if (kv.key is String) kv.key! as String: kv.value,
    };
  }
}

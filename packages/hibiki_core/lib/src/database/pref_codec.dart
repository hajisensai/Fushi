import 'dart:convert';

/// Sentinel distinguishing "the raw string is not in tagged format" from
/// "the raw string is a tagged value that decodes to Dart `null`" (the `z`
/// tag). Using plain `null` for both would make a stored null indistinguishable
/// from an untagged legacy value, sending it down the heuristic path and losing
/// the null. Private + const so no caller can forge or observe it.
class _NotTagged {
  const _NotTagged();
}

const Object _kNotTagged = _NotTagged();

/// Type-tagged preference serialization.
///
/// Format: single-char type tag + colon + value.
/// Tags: `b` (bool), `i` (int), `d` (double), `s` (string), `j` (JSON list),
/// `z` (explicit Dart `null`). Untagged values (written by older code) fall
/// through to heuristic parsing for backward compatibility.
///
/// Null round-trip (TODO-1106 / BUG-532): `encode(null)` emits the `z:` tag so
/// that a preference deliberately set to null (e.g. clearing a book-title
/// override) decodes back to `null`, not the literal string `"null"`. Before
/// the `z` tag, `encode(null)` fell through to `'s:null'` and reload surfaced
/// the four-character string "null" in the UI.
///
/// List support is limited to `List<String>`: [decode] always rebuilds list
/// prefs as `List<String>`. Storing a `List<int>`/`List<double>` and reading
/// it back with a matching default is NOT supported and will throw on the
/// cast. No typed-list pref exists in the codebase; do not add generic
/// `List<T>` support unless a concrete need appears.
class PrefCodec {
  PrefCodec._();

  static String encode(dynamic value) {
    if (value == null) return 'z:';
    if (value is bool) return 'b:$value';
    if (value is int) return 'i:$value';
    if (value is double) return 'd:$value';
    if (value is List) return 'j:${jsonEncode(value)}';
    return 's:$value';
  }

  static T decode<T>(String raw, T defaultValue) {
    final dynamic parsed = _tryTagged(raw);
    if (identical(parsed, _kNotTagged)) {
      return _heuristic<T>(raw, defaultValue);
    }
    if (parsed == null) {
      // Explicit `z:` null. Honour it when T is nullable; otherwise fall back to
      // the (non-null) default so a null can never violate a non-null contract.
      if (null is T) return null as T;
      return defaultValue;
    }
    if (parsed is T) return parsed;
    if (T == double && parsed is int) return parsed.toDouble() as T;
    if (defaultValue is List && parsed is List) {
      return List<String>.from(parsed) as T;
    }
    return defaultValue;
  }

  static dynamic decodeUntyped(String raw) {
    final dynamic parsed = _tryTagged(raw);
    if (identical(parsed, _kNotTagged)) return _heuristicUntyped(raw);
    return parsed;
  }

  /// Returns the decoded value, or the [_kNotTagged] sentinel when [raw] is not
  /// in tagged format. A genuine `null` return means the tagged value decoded
  /// to Dart `null` (the `z` tag, or a malformed `i`/`d`/`j` payload).
  static dynamic _tryTagged(String raw) {
    if (raw.length < 2 || raw[1] != ':') return _kNotTagged;
    final String tag = raw[0];
    final String payload = raw.substring(2);
    switch (tag) {
      case 'z':
        return null;
      case 'b':
        return payload == 'true';
      case 'i':
        return int.tryParse(payload);
      case 'd':
        return double.tryParse(payload);
      case 's':
        return payload;
      case 'j':
        try {
          return jsonDecode(payload);
        } catch (_) {
          return null;
        }
      default:
        return _kNotTagged;
    }
  }

  static T _heuristic<T>(String raw, T defaultValue) {
    if (defaultValue is int) return (int.tryParse(raw) ?? defaultValue) as T;
    if (defaultValue is double) {
      return (double.tryParse(raw) ?? defaultValue) as T;
    }
    if (defaultValue is bool) return (raw == 'true') as T;
    if (defaultValue is List) {
      try {
        return List<String>.from(jsonDecode(raw) as List) as T;
      } catch (_) {
        return defaultValue;
      }
    }
    return raw as T;
  }

  static dynamic _heuristicUntyped(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final int? asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final double? asDouble = double.tryParse(raw);
    if (asDouble != null) return asDouble;
    return raw;
  }
}

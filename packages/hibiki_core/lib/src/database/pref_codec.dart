import 'dart:convert';

/// Type-tagged preference serialization.
///
/// Format: single-char type tag + colon + value.
/// Tags: `b` (bool), `i` (int), `d` (double), `s` (string), `j` (JSON list).
/// Untagged values (written by older code) fall through to heuristic parsing
/// for backward compatibility.
class PrefCodec {
  PrefCodec._();

  static String encode(dynamic value) {
    if (value is bool) return 'b:$value';
    if (value is int) return 'i:$value';
    if (value is double) return 'd:$value';
    if (value is List) return 'j:${jsonEncode(value)}';
    return 's:$value';
  }

  static T decode<T>(String raw, T defaultValue) {
    final dynamic parsed = _tryTagged(raw);
    if (parsed != null) {
      if (parsed is T) return parsed;
      if (T == double && parsed is int) return parsed.toDouble() as T;
      if (defaultValue is List && parsed is List) {
        return List<String>.from(parsed) as T;
      }
      return defaultValue;
    }
    return _heuristic<T>(raw, defaultValue);
  }

  static dynamic decodeUntyped(String raw) {
    final dynamic parsed = _tryTagged(raw);
    if (parsed != null) return parsed;
    return _heuristicUntyped(raw);
  }

  static dynamic _tryTagged(String raw) {
    if (raw.length < 2 || raw[1] != ':') return null;
    final String tag = raw[0];
    final String payload = raw.substring(2);
    switch (tag) {
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
        return null;
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

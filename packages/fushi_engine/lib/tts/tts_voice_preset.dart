/// 声音预设与其持久化。
///
/// 一份预设 = 引擎 + 该引擎的参数（地址、声音、参考音频……）+ 版本号。可以存多份，
/// 有一份是「当前」。整份清单落一个偏好键（JSON），其中 `secret` 类参数按 base64
/// 存（与 `ai_providers` 同一形态）；该键在 `pref_redaction_policy.dart` 点名为凭据，
/// 不进同步 / 备份 / Profile 分享。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';

class TtsVoicePreset {
  const TtsVoicePreset({
    required this.id,
    required this.providerId,
    required this.name,
    this.params = const <String, String>{},
    this.secrets = const <String, String>{},
    this.revision = 0,
  });

  final String id;
  final String providerId;
  final String name;

  /// 非凭据参数。
  final Map<String, String> params;

  /// 凭据参数（API key / Bearer）。只进内存与本机偏好。
  final Map<String, String> secrets;

  /// 用户「重新生成」时自增：进缓存键，旧缓存自然失效。
  final int revision;

  String param(String key, {String? fallback}) =>
      secrets[key] ?? params[key] ?? fallback ?? '';

  TtsVoicePreset copyWith({
    String? name,
    Map<String, String>? params,
    Map<String, String>? secrets,
    int? revision,
  }) => TtsVoicePreset(
    id: id,
    providerId: providerId,
    name: name ?? this.name,
    params: params ?? this.params,
    secrets: secrets ?? this.secrets,
    revision: revision ?? this.revision,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'provider': providerId,
    'name': name,
    'params': params,
    'secretsB64': <String, String>{
      for (final MapEntry<String, String> e in secrets.entries)
        if (e.value.isNotEmpty) e.key: base64Encode(utf8.encode(e.value)),
    },
    'revision': revision,
  };

  static TtsVoicePreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'],
        provider = raw['provider'],
        name = raw['name'];
    if (id is! String ||
        id.isEmpty ||
        provider is! String ||
        provider.isEmpty) {
      return null;
    }
    Map<String, String> strings(Object? value) => <String, String>{
      if (value is Map)
        for (final MapEntry<Object?, Object?> e in value.entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
    };
    final Map<String, String> secrets = <String, String>{};
    strings(raw['secretsB64']).forEach((String key, String value) {
      try {
        secrets[key] = utf8.decode(base64Decode(value));
      } on FormatException {
        // 坏值丢弃：等同未填，用户在设置页会看到「未配置」。
      }
    });
    final Object? revision = raw['revision'];
    return TtsVoicePreset(
      id: id,
      providerId: provider,
      name: name is String ? name : '',
      params: strings(raw['params']),
      secrets: secrets,
      revision: revision is int ? revision : 0,
    );
  }
}

/// 预设清单 + 当前预设 + 朗读倍速的读写。偏好键集中在这里。
class TtsPresetStore {
  TtsPresetStore(this._prefs);

  final PrefStore _prefs;

  static const String presetsKey = 'tts_voice_presets';
  static const String activePresetKey = 'tts_active_preset_id';
  static const String speedKey = 'tts_read_aloud_speed';

  /// 清单是否写过（哪怕写的是空列表）。
  bool get hasStoredPresets {
    final Object? raw = _prefs.getPref(presetsKey, defaultValue: '');
    return raw is String && raw.isNotEmpty;
  }

  List<TtsVoicePreset> loadPresets() {
    final Object? raw = _prefs.getPref(presetsKey, defaultValue: '');
    if (raw is! String || raw.isEmpty) return const <TtsVoicePreset>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <TtsVoicePreset>[];
      return <TtsVoicePreset>[
        for (final Object? item in decoded)
          if (TtsVoicePreset.fromJson(item) case final TtsVoicePreset p) p,
      ];
    } on FormatException {
      return const <TtsVoicePreset>[];
    }
  }

  Future<void> savePresets(List<TtsVoicePreset> presets) => _prefs.setPref(
    presetsKey,
    jsonEncode(<Object?>[for (final TtsVoicePreset p in presets) p.toJson()]),
  );

  String? get activePresetId {
    final Object? raw = _prefs.getPref(activePresetKey, defaultValue: '');
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  Future<void> setActivePresetId(String? id) =>
      _prefs.setPref(activePresetKey, id ?? '');

  /// 当前预设；未选或已删时取清单第一份。
  TtsVoicePreset? activePreset() {
    final List<TtsVoicePreset> presets = loadPresets();
    if (presets.isEmpty) return null;
    final String? id = activePresetId;
    for (final TtsVoicePreset p in presets) {
      if (p.id == id) return p;
    }
    return presets.first;
  }

  double get speed {
    final Object? raw = _prefs.getPref(speedKey, defaultValue: 1.0);
    return raw is num && raw > 0 ? raw.toDouble() : 1.0;
  }

  Future<void> setSpeed(double value) => _prefs.setPref(speedKey, value);

  /// 每本书的朗读断点：章节、该句在章内的匹配坐标起点、句内毫秒、音频缓存键。
  static String resumeKeyFor(String bookKey) => 'tts_resume_$bookKey';

  TtsResumePoint? resumeFor(String bookKey) {
    final Object? raw = _prefs.getPref(resumeKeyFor(bookKey), defaultValue: '');
    if (raw is! String || raw.isEmpty) return null;
    try {
      return TtsResumePoint.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> saveResume(String bookKey, TtsResumePoint point) =>
      _prefs.setPref(resumeKeyFor(bookKey), jsonEncode(point.toJson()));
}

class TtsResumePoint {
  const TtsResumePoint({
    required this.section,
    required this.matchStart,
    required this.offsetMs,
    required this.audioKey,
  });

  final int section;
  final int matchStart;
  final int offsetMs;

  /// 断点那句的缓存键：只有恢复到同一份音频时 [offsetMs] 才有意义。
  final String audioKey;

  Map<String, Object?> toJson() => <String, Object?>{
    's': section,
    'm': matchStart,
    'o': offsetMs,
    'k': audioKey,
  };

  static TtsResumePoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'], m = raw['m'], o = raw['o'], k = raw['k'];
    if (s is! int || m is! int || o is! int || k is! String) return null;
    return TtsResumePoint(section: s, matchStart: m, offsetMs: o, audioKey: k);
  }
}

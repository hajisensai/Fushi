/// 声音指派表：漫画演出稿、小说选角表、系列角色声音档案共用一套。
library;

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';

/// 声音指派表（设计 §5）：作品默认 → 角色 → 角色 × 类型，从粗到细逐级回落；
/// 「叙述」类不属于任何角色，单独一行。值是声音 id（某份声音预设，或某个声音包的
/// 某个参考音频组），null = 用当前朗读声音。
///
/// 两层叠用（[resolveOver]）：一本书 / 一卷自己的表叠在系列档案的表上面，书里没设的
/// 那一级回落到系列，系列也没设再往粗一级走。这样系列里记住的角色声音对新的一卷
/// 自动生效，某一卷要临时换声音只改这一卷，不污染系列。
class CastVoiceAssignment {
  CastVoiceAssignment({
    this.defaultVoice,
    this.narrationVoice,
    Map<String, String>? byCharacter,
    Map<String, Map<CastLineKind, String>>? byCharacterKind,
    List<String>? retryVoices,
  }) : byCharacter = byCharacter ?? <String, String>{},
       byCharacterKind =
           byCharacterKind ?? <String, Map<CastLineKind, String>>{},
       retryVoices = retryVoices ?? <String>[];

  /// 作品默认声音；null = 当前朗读声音。
  String? defaultVoice;

  /// 「叙述」类专用声音；null = 回落到 [defaultVoice]。
  String? narrationVoice;

  /// 角色 → 声音（该角色所有类型）。
  final Map<String, String> byCharacter;

  /// 角色 × 类型 → 声音（只覆盖某一类）。
  final Map<String, Map<CastLineKind, String>> byCharacterKind;

  /// 「切配置重试」的候选声音，按顺序试：某句用指派的声音合成失败后，补回时依次换成
  /// 这里的声音（跳过已经失败过的）。空 = 不自动换声音，只能手动指定。
  final List<String> retryVoices;

  bool get isEmpty =>
      defaultVoice == null &&
      narrationVoice == null &&
      byCharacter.isEmpty &&
      byCharacterKind.isEmpty &&
      retryVoices.isEmpty;

  /// 解析一句该用的声音（纯函数）：叙述类 → 叙述行 → 作品默认；其余 → 角色 × 类型
  /// → 角色 → 作品默认。返回 null = 用当前朗读声音。
  String? resolve(String speaker, CastLineKind kind) =>
      resolveOver(speaker, kind, null);

  /// 叠在 [base]（系列档案）上解析：每一级先看本表、再看 [base]，都没有才往粗一级走。
  String? resolveOver(
    String speaker,
    CastLineKind kind,
    CastVoiceAssignment? base,
  ) {
    if (kind == CastLineKind.narration) {
      return narrationVoice ??
          base?.narrationVoice ??
          defaultVoice ??
          base?.defaultVoice;
    }
    return byCharacterKind[speaker]?[kind] ??
        base?.byCharacterKind[speaker]?[kind] ??
        byCharacter[speaker] ??
        base?.byCharacter[speaker] ??
        defaultVoice ??
        base?.defaultVoice;
  }

  /// 本表与 [base] 合起来的重试候选（本表在前，去重）。
  List<String> retryVoicesOver(CastVoiceAssignment? base) =>
      <String>{...retryVoices, ...?base?.retryVoices}.toList();

  /// 角色改名 / 合并：声音跟着人走；目标已有设置时保留目标的。
  void renameCharacter(String from, String to) {
    if (from == to) return;
    final String? voice = byCharacter.remove(from);
    if (voice != null) byCharacter.putIfAbsent(to, () => voice);
    final Map<CastLineKind, String>? kinds = byCharacterKind.remove(from);
    if (kinds != null) {
      final Map<CastLineKind, String> target = byCharacterKind.putIfAbsent(
        to,
        () => <CastLineKind, String>{},
      );
      kinds.forEach(
        (CastLineKind k, String v) => target.putIfAbsent(k, () => v),
      );
    }
  }

  CastVoiceAssignment copy() => CastVoiceAssignment.fromJson(toJson());

  Map<String, Object?> toJson() => <String, Object?>{
    if (defaultVoice != null) 'default': defaultVoice,
    if (narrationVoice != null) 'narration': narrationVoice,
    if (byCharacter.isNotEmpty) 'char': byCharacter,
    if (byCharacterKind.isNotEmpty)
      'charKind': <String, Object?>{
        for (final MapEntry<String, Map<CastLineKind, String>> e
            in byCharacterKind.entries)
          e.key: <String, String>{
            for (final MapEntry<CastLineKind, String> k in e.value.entries)
              k.key.wire: k.value,
          },
      },
    if (retryVoices.isNotEmpty) 'retry': retryVoices,
  };

  static CastVoiceAssignment fromJson(Object? raw) {
    if (raw is! Map) return CastVoiceAssignment();
    final Object? byChar = raw['char'];
    final Object? byCharKind = raw['charKind'];
    final Object? retry = raw['retry'];
    final Map<String, Map<CastLineKind, String>> kinds =
        <String, Map<CastLineKind, String>>{};
    if (byCharKind is Map) {
      for (final MapEntry<Object?, Object?> e in byCharKind.entries) {
        final Object? key = e.key;
        final Object? inner = e.value;
        if (key is! String || inner is! Map) continue;
        final Map<CastLineKind, String> m = <CastLineKind, String>{};
        for (final MapEntry<Object?, Object?> k in inner.entries) {
          final CastLineKind? kind = CastLineKind.parse(k.key);
          final Object? voice = k.value;
          if (kind != null && voice is String) m[kind] = voice;
        }
        if (m.isNotEmpty) kinds[key] = m;
      }
    }
    final Object? def = raw['default'];
    final Object? narration = raw['narration'];
    return CastVoiceAssignment(
      defaultVoice: def is String ? def : null,
      narrationVoice: narration is String ? narration : null,
      byCharacter: <String, String>{
        if (byChar is Map)
          for (final MapEntry<Object?, Object?> e in byChar.entries)
            if (e.key is String && e.value is String)
              e.key! as String: e.value! as String,
      },
      byCharacterKind: kinds,
      retryVoices: <String>[
        if (retry is List)
          for (final Object? v in retry)
            if (v is String && v.isNotEmpty) v,
      ],
    );
  }
}

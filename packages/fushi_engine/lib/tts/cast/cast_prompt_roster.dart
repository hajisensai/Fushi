/// AI 请求临时角色表：自由文字先替换，回复再恢复为已有角色身份。
/// 不改持久化角色表 / 声音表，也不把原词与替换词的对照表送给模型。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

const String _idPrefix = '_cast_';

String _key(String name) => name.trim().toLowerCase();

const Set<String> _reserved = <String>{
  kTtsNarrator,
  kTtsUnknown,
  'narrator',
  'narration',
  'unknown',
  '旁白',
  '不明',
  '未知',
  'ナレーター',
  'ナレーション',
  '地の文',
  '語り手',
  '?',
  '？',
  '???',
};

class CastPromptRoster {
  factory CastPromptRoster({
    required Iterable<TtsCastCharacter> roster,
    List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
  }) {
    final List<TtsCastCharacter> source = roster.toList();
    final Map<String, Set<String>> nameOwners = <String, Set<String>>{};
    final Map<String, Set<String>> aliasOwners = <String, Set<String>>{};
    final Map<String, String> projected = <String, String>{};
    final Map<String, String> originalNames = <String, String>{};
    for (final TtsCastCharacter c in source) {
      final String name = applyCastSubstitutions(c.name, substitutions).trim();
      projected[c.name] = name;
      (nameOwners[_key(name)] ??= <String>{}).add(c.name);
      originalNames[_key(c.name)] = c.name;
      for (final String alias in c.aliases) {
        final String changed = applyCastSubstitutions(
          alias,
          substitutions,
        ).trim();
        (aliasOwners[_key(changed)] ??= <String>{}).add(c.name);
      }
    }
    for (final TtsCastCharacter c in source) {
      for (final String alias in c.aliases) {
        originalNames.putIfAbsent(_key(alias), () => c.name);
      }
    }
    final Set<String> ambiguous = <String>{
      for (final MapEntry<String, Set<String>> e in nameOwners.entries)
        if (e.value.length > 1) e.key,
      for (final MapEntry<String, Set<String>> e in aliasOwners.entries)
        if (e.value.length > 1 && !nameOwners.containsKey(e.key)) e.key,
    };
    final Set<String> used = <String>{...nameOwners.keys, ...aliasOwners.keys};
    final Map<String, String> names = <String, String>{};
    // 摘要基于原规范名，不受角色出场顺序、替换表顺序或后续添人影响。
    for (final TtsCastCharacter c in source) {
      String name = projected[c.name]!;
      final String key = _key(name);
      if (key.isEmpty ||
          name.length > 40 ||
          _reserved.contains(key) ||
          key.startsWith(_idPrefix) ||
          ambiguous.contains(key)) {
        int salt = 0;
        do {
          final String input = salt == 0 ? c.name : '${c.name}\u0000$salt';
          name =
              '$_idPrefix${sha256.convert(utf8.encode(input)).toString().substring(0, 32)}';
          salt++;
        } while (!used.add(_key(name)));
      }
      names[c.name] = name;
    }
    final Map<String, String> replies = <String, String>{
      for (final TtsCastCharacter c in source) _key(names[c.name]!): c.name,
    };
    final List<TtsCastCharacter> characters = <TtsCastCharacter>[];
    for (final TtsCastCharacter c in source) {
      final String name = names[c.name]!;
      final Set<String> aliases = <String>{};
      for (final String alias in c.aliases) {
        final String changed = applyCastSubstitutions(
          alias,
          substitutions,
        ).trim();
        final String key = _key(changed);
        if (key.isEmpty ||
            key == _key(name) ||
            _reserved.contains(key) ||
            key.startsWith(_idPrefix) ||
            ambiguous.contains(key) ||
            aliasOwners[key]!.length != 1 ||
            (replies.containsKey(key) && replies[key] != c.name)) {
          continue;
        }
        aliases.add(changed);
        replies[key] = c.name;
      }
      characters.add(
        TtsCastCharacter(
          name: name,
          aliases: aliases.toList(),
          gender: c.gender,
          age: c.age,
          description: c.description == null
              ? null
              : applyCastSubstitutions(c.description!, substitutions),
        ),
      );
    }
    return CastPromptRoster._(
      List<TtsCastCharacter>.unmodifiable(characters),
      names,
      originalNames,
      replies,
      ambiguous,
      List<CastTextSubstitution>.of(substitutions),
    );
  }

  CastPromptRoster._(
    this.characters,
    this._names,
    this._originalNames,
    this._replies,
    this._ambiguous,
    this._substitutions,
  );

  final List<TtsCastCharacter> characters;
  final Map<String, String> _names;
  final Map<String, String> _originalNames;
  final Map<String, String> _replies;
  final Set<String> _ambiguous;
  final List<CastTextSubstitution> _substitutions;

  /// 本地角色名 / 别名 → 本次请求里的规范名；旁白 / 不明的协议身份不替换。
  String speakerFor(String original) {
    if (original == kTtsNarrator || original == kTtsUnknown) return original;
    final String? canonical = _originalNames[_key(original)];
    return _names[original] ??
        _names[canonical] ??
        applyCastSubstitutions(original, _substitutions);
  }

  /// 模型回的本次规范名 / 无歧义别名 → 持久化规范名；表外名返回 null。
  String? canonicalName(String reply) => _replies[_key(reply)];

  /// 名字类回复：已有角色恢复身份，新名字保留；歧义名 / 未知临时 ID 丢弃。
  String? restoreName(String reply) {
    final String name = reply.trim();
    final String key = _key(name);
    return _replies[key] ??
        (key.isEmpty || _ambiguous.contains(key) || key.startsWith(_idPrefix)
            ? null
            : name);
  }

  /// 归属类回复：歧义名字变成「不明」，不能把两个旧角色误合并。
  String restoreSpeaker(String reply) => restoreName(reply) ?? kTtsUnknown;

  /// 已知投影别名只是对旧档案的复述，不把临时名字 / 别人的别名写回档案。
  List<String> restoreAliases(
    Iterable<String> aliases, {
    required String owner,
  }) => <String>[
    for (final String alias in aliases)
      if (restoreName(alias) case final String restored)
        if (canonicalName(alias) == null && _key(restored) != _key(owner))
          restored,
  ];

  TtsCastCharacter? restoreCharacter(TtsCastCharacter character) {
    final String? name = restoreName(character.name);
    if (name == null) return null;
    return TtsCastCharacter(
      name: name,
      aliases: restoreAliases(character.aliases, owner: name),
      gender: character.gender,
      age: character.age,
      description: character.description,
    );
  }
}

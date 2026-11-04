import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_web_search_section.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/web_search.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  Future<PreferencesRepository> reloaded() async {
    final PreferencesRepository fresh = PreferencesRepository(db);
    await fresh.loadFromDb();
    return fresh;
  }

  /// 落盘的原始 JSON（绕过偏好缓存直接读库）。
  Future<Map<String, Object?>> storedJson() async {
    final String raw = (await db.getAllPrefs())['ai_web_search']!;
    return (jsonDecode(PrefCodec.decode(raw, '') as String) as Map)
        .cast<String, Object?>();
  }

  test('默认没配 = null；写入后重载仍在；写 null 清空', () async {
    expect(prefs.aiWebSearchConfig, isNull);
    const WebSearchConfig cfg = WebSearchConfig(
      kind: WebSearchKind.searxng,
      endpoint: 'https://s.example.org',
    );
    await prefs.setAiWebSearch(cfg);
    expect(prefs.aiWebSearchConfig, cfg);
    expect((await reloaded()).aiWebSearchConfig, cfg);
    await prefs.setAiWebSearch(null);
    expect(prefs.aiWebSearchConfig, isNull);
    expect((await reloaded()).aiWebSearchConfig, isNull);
  });

  test('坏 JSON 读成 null', () async {
    await prefs.setPref('ai_web_search', '{oops');
    expect(prefs.aiWebSearchConfig, isNull);
  });

  test('Brave key 与 ai_providers 同一存法：base64 apiKeyB64，不落明文', () async {
    await prefs.setAiWebSearch(
      const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'tok-秘密'),
    );
    final Map<String, Object?> stored = await storedJson();
    expect(stored.containsKey('apiKey'), isFalse);
    expect(stored['apiKeyB64'], base64Encode(utf8.encode('tok-秘密')));
    expect((await reloaded()).aiWebSearchConfig!.apiKey, 'tok-秘密');
    // 与 ai_providers 同样登记成凭据（不进日志 / 明文导出）。
    expect(kCredentialPreferenceKeys, contains('ai_web_search'));
  });

  test('旧版明文 apiKey：启动时就地迁成 apiKeyB64，key 不丢', () async {
    await prefs.setPref(
      'ai_web_search',
      '{"kind":"brave","apiKey":" legacy-tok "}',
    );
    final PreferencesRepository fresh = await reloaded();
    expect(fresh.aiWebSearchConfig!.apiKey, 'legacy-tok');
    final Map<String, Object?> stored = await storedJson();
    expect(stored.containsKey('apiKey'), isFalse);
    expect(stored['apiKeyB64'], base64Encode(utf8.encode('legacy-tok')));
    expect(stored['kind'], 'brave');
  });

  test('新形状 / 没配时启动不重写', () async {
    await prefs.setAiWebSearch(
      const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
    );
    final String before = (await db.getAllPrefs())['ai_web_search']!;
    await reloaded();
    expect((await db.getAllPrefs())['ai_web_search'], before);
    expect(WebSearchConfig.needsStorageMigration(null), isFalse);
    expect(WebSearchConfig.needsStorageMigration('{oops'), isFalse);
  });

  test('抓页确认：没答过 / 不允许时 AI 功能读不到联网搜索，允许后生效并持久化', () async {
    const WebSearchConfig cfg = WebSearchConfig(
      kind: WebSearchKind.brave,
      apiKey: 'k',
    );
    await prefs.setAiWebSearch(cfg);
    expect(prefs.aiWebSearchPageFetchDecision, '');
    expect(prefs.aiWebSearch, isNull);

    await prefs.setAiWebSearchPageFetchAllowed(false);
    expect(prefs.aiWebSearchPageFetchDecision, kAiWebSearchPageFetchDeny);
    expect(prefs.aiWebSearch, isNull);

    await prefs.setAiWebSearchPageFetchAllowed(true);
    expect(prefs.aiWebSearch, cfg);
    final PreferencesRepository fresh = await reloaded();
    expect(fresh.aiWebSearchPageFetchDecision, kAiWebSearchPageFetchAllow);
    expect(fresh.aiWebSearch, cfg);
    expect(kKnownPreferenceKeys, contains(kAiWebSearchPageFetchPref));
  });

  test('设置项助手：切后端保留已填字段，关闭清空', () async {
    expect(aiWebSearchKindValue(prefs), kAiWebSearchOff);
    // 没选后端时改地址 / key 不生效。
    await setAiWebSearchEndpoint(prefs, 'https://x.org');
    expect(prefs.aiWebSearchConfig, isNull);

    await setAiWebSearchKind(prefs, 'searxng');
    await setAiWebSearchEndpoint(prefs, ' https://s.example.org ');
    expect(prefs.aiWebSearchConfig!.endpoint, 'https://s.example.org');
    expect(prefs.aiWebSearchConfig!.isUsable, isTrue);

    await setAiWebSearchKind(prefs, 'brave');
    expect(aiWebSearchKindValue(prefs), 'brave');
    expect(prefs.aiWebSearchConfig!.isUsable, isFalse);
    await setAiWebSearchApiKey(prefs, 'tok');
    expect(prefs.aiWebSearchConfig!.apiKey, 'tok');
    expect(prefs.aiWebSearchConfig!.isUsable, isTrue);

    await setAiWebSearchApiKey(prefs, '  ');
    expect(prefs.aiWebSearchConfig!.apiKey, isNull);

    await setAiWebSearchKind(prefs, kAiWebSearchOff);
    expect(prefs.aiWebSearchConfig, isNull);
  });
}

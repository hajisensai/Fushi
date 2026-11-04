import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('默认没配 = null；写入后重载仍在；写 null 清空', () async {
    expect(prefs.aiWebSearch, isNull);
    const WebSearchConfig cfg = WebSearchConfig(
      kind: WebSearchKind.searxng,
      endpoint: 'https://s.example.org',
    );
    await prefs.setAiWebSearch(cfg);
    expect(prefs.aiWebSearch, cfg);
    expect((await reloaded()).aiWebSearch, cfg);
    await prefs.setAiWebSearch(null);
    expect(prefs.aiWebSearch, isNull);
    expect((await reloaded()).aiWebSearch, isNull);
  });

  test('坏 JSON 读成 null', () async {
    await prefs.setPref('ai_web_search', '{oops');
    expect(prefs.aiWebSearch, isNull);
  });

  test('设置项助手：切后端保留已填字段，关闭清空', () async {
    expect(aiWebSearchKindValue(prefs), kAiWebSearchOff);
    // 没选后端时改地址 / key 不生效。
    await setAiWebSearchEndpoint(prefs, 'https://x.org');
    expect(prefs.aiWebSearch, isNull);

    await setAiWebSearchKind(prefs, 'searxng');
    await setAiWebSearchEndpoint(prefs, ' https://s.example.org ');
    expect(prefs.aiWebSearch!.endpoint, 'https://s.example.org');
    expect(prefs.aiWebSearch!.isUsable, isTrue);

    await setAiWebSearchKind(prefs, 'brave');
    expect(aiWebSearchKindValue(prefs), 'brave');
    expect(prefs.aiWebSearch!.isUsable, isFalse);
    await setAiWebSearchApiKey(prefs, 'tok');
    expect(prefs.aiWebSearch!.apiKey, 'tok');
    expect(prefs.aiWebSearch!.isUsable, isTrue);

    await setAiWebSearchApiKey(prefs, '  ');
    expect(prefs.aiWebSearch!.apiKey, isNull);

    await setAiWebSearchKind(prefs, kAiWebSearchOff);
    expect(prefs.aiWebSearch, isNull);
  });
}

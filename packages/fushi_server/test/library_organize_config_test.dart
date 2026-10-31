import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:test/test.dart';

/// 服务端「扫描入库后自动 AI 整理库」（yaml `ai.library_organize`，spec
/// docs/specs/2026-10-20-ai-library-organize-design.md §10.2）：默认关；只有打开且提供商
/// 能用时才给扫描器整理服务、才把「AI 整理库」指派给那一家；yaml 往返不丢。
void main() {
  const String yaml = '''
ai:
  preset: "openai"
  api_key: "sk-x"
  library_organize: true
''';

  test('yaml 往返保留 library_organize', () {
    final ServerConfig config = ServerConfig.parse(yaml, configDir: '.');
    expect(config.ai!.libraryOrganize, isTrue);
    final ServerConfig again = ServerConfig.parse(
      config.toYaml(),
      configDir: '.',
    );
    expect(again.ai!.libraryOrganize, isTrue);
    expect(
      ServerConfig.parse(
        'ai:\n  preset: "openai"\n  api_key: "sk-x"\n',
        configDir: '.',
      ).ai!.libraryOrganize,
      isFalse,
      reason: '默认关：按量计费，绝不静默开启',
    );
  });

  test('只有打开时才指派「AI 整理库」、才给扫描器整理服务', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ServerAiConfig on = ServerConfig.parse(yaml, configDir: '.').ai!;
    final ServerAiConfig off = on.copyWith(libraryOrganize: false);
    expect(
      ServerAiSettings(
        () => on,
      ).aiFeatureAssignments.providerIdFor(AiFeature.libraryOrganize),
      kServerAiProviderId,
    );
    expect(
      ServerAiSettings(
        () => off,
      ).aiFeatureAssignments.providerIdFor(AiFeature.libraryOrganize),
      isNull,
    );
    expect(serverLibraryOrganizer(db, on), isNotNull);
    expect(serverLibraryOrganizer(db, off), isNull);
    expect(serverLibraryOrganizer(db, null), isNull);
  });
}

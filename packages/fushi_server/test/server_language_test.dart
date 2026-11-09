import 'dart:io';

import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi_lang_');
  });

  tearDown(() async {
    serverLanguage = ServerConfig.defaultLanguage;
    await dir.delete(recursive: true);
  });

  String writeConfig(String name, String body) {
    final File f = File(p.join(dir.path, name));
    f.writeAsStringSync(body);
    return f.path;
  }

  String resolve(List<String> args, {Map<String, String>? env}) =>
      resolveServerLanguage(
        args,
        defaultConfigFileName: p.join(dir.path, 'fushi_server.yaml'),
        environment: env ?? const <String, String>{},
      );

  test('tr 按当前语言二选一；不认识的语言回落英文', () {
    serverLanguage = 'zh';
    expect(tr('中', 'en'), '中');
    serverLanguage = ' EN ';
    expect(tr('中', 'en'), 'en');
    serverLanguage = 'fr';
    expect(serverLanguage, ServerConfig.languageEnglish);
  });

  test('没有配置文件 → 默认英文', () {
    expect(resolve(const <String>['status']), ServerConfig.languageEnglish);
  });

  test('读缺省配置文件里的 language（带引号、带注释都认）', () {
    writeConfig('fushi_server.yaml', 'port: 1\nlanguage: "zh"   # 中文\n');
    expect(resolve(const <String>['status']), ServerConfig.languageChinese);
  });

  test('--config / --config= / -c 指向的文件', () {
    final String cfg = writeConfig('other.yaml', 'language: zh\n');
    expect(resolve(<String>['--config', cfg, 'status']), 'zh');
    expect(resolve(<String>['--config=$cfg', 'status']), 'zh');
    expect(resolve(<String>['-c', cfg, 'status']), 'zh');
    expect(resolve(<String>['-c$cfg', 'status']), 'zh');
  });

  test('FUSHI_LANGUAGE 优先于配置；非法值忽略', () {
    writeConfig('fushi_server.yaml', 'language: zh\n');
    expect(
      resolve(
        const <String>[],
        env: <String, String>{kServerLanguageEnv: 'en'},
      ),
      'en',
    );
    expect(
      resolve(
        const <String>[],
        env: <String, String>{kServerLanguageEnv: 'xx'},
      ),
      'zh',
    );
  });

  test('配置里写了不认识的值或文件写坏了 → 默认英文，不抛', () {
    writeConfig('fushi_server.yaml', 'language: fr\n: : [\n');
    expect(resolve(const <String>[]), ServerConfig.languageEnglish);
  });

  test('旧配置（文件在、没有 language 行）→ 中文，与 ServerConfig.parse 一致', () {
    final String cfg = writeConfig('fushi_server.yaml', 'port: 1\n');
    expect(resolve(const <String>[]), ServerConfig.languageChinese);
    expect(
      ServerConfig.parse(
        File(cfg).readAsStringSync(),
        configDir: dir.path,
      ).language,
      ServerConfig.languageChinese,
    );
  });

  test('init --language 写进配置，之后的命令按它出', () async {
    final String cfg = p.join(dir.path, 'fushi_server.yaml');
    final int code = await runFushiServerCli(<String>[
      '--config',
      cfg,
      'init',
      '--language',
      'zh',
    ]);
    expect(code, 0);
    final ServerConfig c = await ServerConfig.load(File(cfg));
    expect(c.language, ServerConfig.languageChinese);
    expect(serverLanguage, ServerConfig.languageChinese);
    expect(resolve(<String>['--config', cfg, 'status']), 'zh');
  });

  test('init 不给 --language → 默认英文', () async {
    final String cfg = p.join(dir.path, 'fushi_server.yaml');
    expect(await runFushiServerCli(<String>['--config', cfg, 'init']), 0);
    final ServerConfig c = await ServerConfig.load(File(cfg));
    expect(c.language, ServerConfig.languageEnglish);
  });
}

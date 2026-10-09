/// 离线命令模块测试的共用夹具：临时数据目录 + 配置文件 + 捕获输出。
///
/// 走真实的 `withServerRuntime`（真 FushiDatabase 文件库、宿主装配），断言完再
/// 用 [CommandHarness.openDb] 重新打开同一份库查落库结果。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;

class CommandHarness {
  CommandHarness._(this.tmp, this.configFile);

  final Directory tmp;
  final File configFile;
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();

  String get dataDir => p.join(tmp.path, 'data');

  /// 建临时目录；[withConfig] 为 false 时不写配置文件（测「缺配置 → 66」）。
  static Future<CommandHarness> create({bool withConfig = true}) async {
    final Directory tmp = await Directory.systemTemp.createTemp('fushi_server_cmd_');
    final File config = File(p.join(tmp.path, 'fushi_server.yaml'));
    final CommandHarness h = CommandHarness._(tmp, config);
    if (withConfig) await ServerConfig.defaults(dataDir: h.dataDir).save(config);
    return h;
  }

  CommandIo get io => CommandIo(out: out, err: err);

  /// 像 `fushi_server <args>` 那样把 [args] 交给 [module]（只登记这一个模块）。
  Future<int> run(CliModule module, List<String> args) async {
    out.clear();
    err.clear();
    final ArgParser parser = ArgParser();
    module.register(parser);
    final ArgResults results = parser.parse(args);
    final ArgResults command = results.command!;
    return module.run(command.name!, command, CliContext(configFile: configFile, verbose: false));
  }

  /// `--json` 输出解析回 map。
  Map<String, Object?> json() => (jsonDecode(out.toString()) as Map<Object?, Object?>).cast<String, Object?>();

  /// 重新打开命令写过的那份库（命令结束时已关闭）。
  FushiDatabase openDb() => FushiDatabase(p.join(dataDir, 'support'));

  Future<void> dispose() async {
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
}

/// 现造一本最小 EPUB（单章正文 [body]）。
void writeTestEpub(String path, String title, {String body = 'Hello.'}) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  add('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>$body</p></body>
</html>
''');
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
}

/// 最小 mokuro 卷（`<dir>/<title>.mokuro` + `images/p001.jpg`）。
void writeTestMokuro(String dir, String title) {
  File(p.join(dir, 'images', 'p001.jpg'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(dir, '$title.mokuro')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'version': '0.2.0',
      'title': title,
      'pages': <Object?>[
        <String, Object?>{'img_width': 800, 'img_height': 1200, 'img_path': 'images/p001.jpg', 'blocks': <Object?>[]},
      ],
    }),
  );
}

// 把 templates/fushi_card/ 下的模板源文件（front.html / back.html / styling.css）
// 生成为 lib/src/fushi_card_template_data.dart 里的 Dart 常量。
//
// 用法（在 packages/fushi_anki/ 下）：dart run tool/gen_fushi_card_template.dart
//
// 模板源文件是唯一真相：改模板只改那三个文件，再跑本脚本。生成结果与源文件是否一致由
// test/fushi_card_template_sync_test.dart 守着（忘了重新生成会红）。
import 'dart:io';

import '../test/support/fushi_card_template_codegen.dart';

void main() {
  final File out = File(kFushiCardTemplateDataPath);
  out.writeAsStringSync(renderFushiCardTemplateData(Directory.current));
  stdout.writeln('wrote ${out.path}');
}

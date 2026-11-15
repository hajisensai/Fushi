/// Fushi 卡片模板源文件 → Dart 常量的生成逻辑（生成脚本与同步守卫测试共用）。
library;

import 'dart:io';

import 'package:fushi_anki/src/fushi_card_blocks.dart'
    show fushiCardMarkedSkeletonOf, fushiCardSha256, kFushiCardSkeletonMarker;

/// 生成文件相对包根的路径。
const String kFushiCardTemplateDataPath =
    'lib/src/fushi_card_template_data.dart';

/// 模板源文件目录（相对包根）。
const String kFushiCardTemplateSourceDir = 'templates/fushi_card';

String _rawLiteral(String name, String content) {
  if (content.contains("'''")) {
    throw StateError(
      '$name contains a triple quote; cannot embed as raw string',
    );
  }
  return "const String $name = r'''$content''';\n";
}

/// 正面 / 背面模板末尾的自证骨架标记（见 fushi_card_blocks.dart 的 [kFushiCardSkeletonMarker]）：
/// 内置模板与区块布局生成的模板都带它，更旧的代码不认识这版骨架时据此认出骨架没被手改。
String _withSkeletonMarker(String template) {
  final String? skeleton = fushiCardMarkedSkeletonOf(template);
  if (skeleton == null) {
    throw StateError('Fushi Card template has broken block markup');
  }
  final String body = template.endsWith('\n') ? template : '$template\n';
  return '$body<!--$kFushiCardSkeletonMarker:${fushiCardSha256(skeleton)}-->\n';
}

/// 按 [packageRoot] 下的模板源文件渲染生成文件的完整内容。
String renderFushiCardTemplateData(Directory packageRoot) {
  String read(String file) => File(
    '${packageRoot.path}/$kFushiCardTemplateSourceDir/$file',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final StringBuffer b = StringBuffer()
    ..writeln('// GENERATED FILE — DO NOT EDIT.')
    ..writeln(
      '// 源文件：packages/fushi_anki/$kFushiCardTemplateSourceDir/'
      '{front.html,back.html,styling.css}',
    )
    ..writeln(
      '// 重新生成：在 packages/fushi_anki/ 下 '
      'dart run tool/gen_fushi_card_template.dart',
    )
    ..writeln()
    ..writeln('/// Fushi 卡片模板 · 正面。')
    ..write(
      _rawLiteral(
        'kFushiCardFrontTemplate',
        _withSkeletonMarker(read('front.html')),
      ),
    )
    ..writeln()
    ..writeln('/// Fushi 卡片模板 · 背面。')
    ..write(
      _rawLiteral(
        'kFushiCardBackTemplate',
        _withSkeletonMarker(read('back.html')),
      ),
    )
    ..writeln()
    ..writeln('/// Fushi 卡片模板 · 样式。')
    ..write(_rawLiteral('kFushiCardStylingCss', read('styling.css')));
  return b.toString();
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/fushi_card_template_codegen.dart';

void main() {
  test(
    'generated Fushi card template constants match the template sources',
    () {
      final String expected = renderFushiCardTemplateData(Directory.current);
      final String actual = File(
        kFushiCardTemplateDataPath,
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        actual,
        expected,
        reason:
            'templates/fushi_card/ changed without regenerating; run '
            'dart run tool/gen_fushi_card_template.dart in packages/fushi_anki',
      );
    },
  );
}

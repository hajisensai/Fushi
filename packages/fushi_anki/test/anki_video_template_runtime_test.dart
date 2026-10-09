import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

void main() {
  test(
    'managed player owns autoplay, replay and card-change cleanup',
    () async {
      final AnkiNoteTypeDefinition patched = applyAnkiVideoTemplate(
        const AnkiNoteTypeDefinition(
          name: 'Custom',
          fields: <String>['Picture'],
          templates: <AnkiCardTemplate>[
            AnkiCardTemplate(name: 'Card', front: '', back: '{{Picture}}'),
          ],
          css: '',
        ),
        const AnkiVideoTemplateOptions(field: 'Picture'),
      );
      final String script = RegExp(
        r'<script>(.*?)</script>',
        dotAll: true,
      ).firstMatch(patched.templates.single.back)!.group(1)!;
      final File fixture = <File>[
        File('test/fixtures/video_adapter_runtime.cjs'),
        File('../packages/fushi_anki/test/fixtures/video_adapter_runtime.cjs'),
      ].firstWhere((File file) => file.existsSync());
      final Process node = await Process.start('node', <String>[
        fixture.absolute.path,
      ]);
      final Future<String> stdout = node.stdout.transform(utf8.decoder).join();
      final Future<String> stderr = node.stderr.transform(utf8.decoder).join();
      node.stdin.add(utf8.encode(script));
      await node.stdin.close();
      final int exitCode = await node.exitCode;
      expect(exitCode, 0, reason: '${await stdout}\n${await stderr}');
    },
  );
}

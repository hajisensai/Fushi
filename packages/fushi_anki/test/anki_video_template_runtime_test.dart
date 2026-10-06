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
      final Directory temp = await Directory.systemTemp.createTemp(
        'fushi_video_player_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File scriptFile = File('${temp.path}/player.js')
        ..writeAsStringSync(script);
      final ProcessResult result = await Process.run('node', <String>[
        fixture.absolute.path,
        scriptFile.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}

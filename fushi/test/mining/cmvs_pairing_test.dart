import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cmvs fixture pairs the selected thread with DirectSound PCM', () async {
    final Map<String, dynamic> data = jsonDecode(
      await File(
        'test/fixtures/galhook/cmvs_replay.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    expect(data['status'], 'implemented_unverified');

    final Map<String, dynamic> config = data['config'] as Map<String, dynamic>;
    // CMVS 没有可抽取的逐句资源，PCM 是它的最好档；loopback 仍须排在最后。
    expect(config['audio_priority'], <String>[
      'resource_audio',
      'pcm',
      'loopback',
    ]);
    expect(config['selected_thread'], 7);

    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    final List<dynamic> cards = expected['cards'] as List<dynamic>;
    expect(cards.single, <String, dynamic>{
      'text_id': 'cmvs-line',
      'audio_backend': 'pcm',
      'audio_id': 'cmvs-directsound-pcm',
    });
    // thread 8 是 UI 线程，必须被线程过滤挡掉——这条掉了就等于没在选线程。
    expect(expected['thread_filtered_events'], 1);
    expect(expected['duplicate_text_events'], 0);
    expect(expected['session_clean'], isTrue);
  });

  // 同一份 replay fixture 在两棵树各存一份：`fushi/test/fixtures/galhook/` 给 Dart 侧，
  // `native/galgame_hook/tests/fixtures/` 给 `tools/galhook.py replay` 与 ctest。
  //
  // 没有这条守卫时，两份可以静默分叉到天各一方——改其中一份，另一份的消费者照样全绿，
  // 而「Dart 侧断言的行为」和「native 侧 replay 验的行为」就此不再是同一件事。
  //
  // 按目录枚举而不是硬编码引擎名：将来新增引擎的 fixture 自动落进扫描面。
  test('galhook replay fixture 在 Dart 与 native 两棵树逐字节一致', () {
    final Directory dartDir = Directory('test/fixtures/galhook');
    final Directory nativeDir = Directory(
      '../native/galgame_hook/tests/fixtures',
    );
    expect(
      dartDir.existsSync() && nativeDir.existsSync(),
      isTrue,
      reason: 'fixture 目录搬家了，这条守卫要跟着改，别让它静默变成空跑',
    );

    final List<String> compared = <String>[];
    for (final FileSystemEntity e in dartDir.listSync()) {
      if (e is! File || !e.path.endsWith('_replay.json')) continue;
      final String name = e.uri.pathSegments.last;
      final File twin = File('${nativeDir.path}/$name');
      if (!twin.existsSync()) continue; // 只有 Dart 侧有的（纯 Dart 用例）不管
      compared.add(name);
      expect(
        e.readAsBytesSync(),
        twin.readAsBytesSync(),
        reason: '$name 两棵树已分叉：Dart 测试与 native replay 验的不再是同一份行为',
      );
    }
    expect(
      compared,
      contains('cmvs_replay.json'),
      reason: '至少 cmvs 这一对必须被比到，否则本条守卫是空跑',
    );
  });
}

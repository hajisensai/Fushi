import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());

  test('appendLine adds and notifies', () {
    int notifications = 0;
    void listener() => notifications++;
    TexthookerService.instance.addListener(listener);

    TexthookerService.instance.appendLine('一行目');
    TexthookerService.instance.appendLine('二行目');

    expect(TexthookerService.instance.lines, ['一行目', '二行目']);
    expect(notifications, 2);
    TexthookerService.instance.removeListener(listener);
  });

  test('blank lines are ignored', () {
    TexthookerService.instance.appendLine('   ');
    TexthookerService.instance.appendLine('');
    expect(TexthookerService.instance.lines, isEmpty);
  });

  test('buffer caps at maxLines, dropping oldest', () {
    final TexthookerLineEntry first =
        TexthookerService.instance.appendLine('first')!;
    for (int i = 0; i < TexthookerService.maxLines + 10; i++) {
      TexthookerService.instance.appendLine('line $i');
    }
    expect(TexthookerService.instance.lines.length, TexthookerService.maxLines);
    expect(TexthookerService.instance.lines.first, 'line 10');
    expect(TexthookerService.instance.entryById(first.id), isNull,
        reason: 'an evicted line must not silently resolve to newer text');
  });

  test('clear empties and notifies', () {
    TexthookerService.instance.appendLine('x');
    int notifications = 0;
    TexthookerService.instance.addListener(() => notifications++);
    TexthookerService.instance.clear();
    expect(TexthookerService.instance.lines, isEmpty);
    expect(notifications, 1);
  });

  test('duplicate sentences keep distinct stable ids and audio state', () {
    final DateTime receivedAt = DateTime(2026, 7, 19, 12);
    final TexthookerLineEntry first = TexthookerService.instance.appendLine(
      '同じ台詞',
      source: TexthookerLineSource.engineHook,
      sourceSequence: 41,
      receivedAt: receivedAt,
    )!;
    final TexthookerLineEntry second = TexthookerService.instance.appendLine(
      '同じ台詞',
      source: TexthookerLineSource.engineHook,
      sourceSequence: 42,
      receivedAt: receivedAt,
    )!;

    expect(first.id, isNot(second.id));
    expect(TexthookerService.instance.entries, hasLength(2));
    expect(TexthookerService.instance.entryById(first.id), same(first));
    expect(TexthookerService.instance.entryById(second.id), same(second));

    expect(
      TexthookerService.instance.updateLineAudio(
        second.id,
        status: TexthookerLineAudioStatus.encoded,
        backend: 'game_resource',
        resourceId: '12345.voice.ogg',
        durationMs: 840,
      ),
      isTrue,
    );
    expect(
      TexthookerService.instance.entries.first.audioStatus,
      TexthookerLineAudioStatus.unavailable,
    );
    expect(
      TexthookerService.instance.entries.last.audioStatus,
      TexthookerLineAudioStatus.encoded,
    );
    expect(
      TexthookerService.instance.entries.last.audioResourceId,
      '12345.voice.ogg',
    );
  });

  test('text threads are aggregated and can filter mixed Luna output', () {
    final DateTime firstAt = DateTime(2026, 7, 19, 12);
    final DateTime secondAt = firstAt.add(const Duration(seconds: 1));
    TexthookerService.instance.appendLine(
      '坏线程文本',
      textThreadKey: 'luna:bad',
      textThreadLabel: 'Luna 0x1000',
      textHookCode: 'HS932@1000',
      receivedAt: firstAt,
    );
    TexthookerService.instance.appendLine(
      '干净文本一',
      textThreadKey: 'luna:clean',
      textThreadLabel: 'SiglusEngine 0x2000',
      textHookCode: 'HS932@2000',
      nativeTextThreadId: 0xCAFE,
      receivedAt: secondAt,
    );
    TexthookerService.instance.appendLine(
      '干净文本二',
      textThreadKey: 'luna:clean',
      textThreadLabel: 'SiglusEngine 0x2000',
      textHookCode: 'HS932@2000',
      receivedAt: secondAt.add(const Duration(milliseconds: 1)),
    );

    expect(TexthookerService.instance.textThreads, hasLength(2));
    expect(TexthookerService.instance.textThreads.first.key, 'luna:clean');
    expect(TexthookerService.instance.textThreads.first.lineCount, 2);
    expect(
      TexthookerService.instance.textThreads.first.nativeThreadId,
      0xCAFE,
    );
    expect(
      TexthookerService.instance
          .entriesForTextThread('luna:clean')
          .map((entry) => entry.text),
      <String>['干净文本一', '干净文本二'],
    );
    expect(
      TexthookerService.instance.entriesForTextThread(null),
      hasLength(3),
    );
  });

  test('discovered Luna thread is selectable before it publishes a line', () {
    final DateTime discoveredAt = DateTime(2026, 7, 21, 12);
    TexthookerService.instance.registerTextThread(
      key: 'luna:textrender',
      label: 'TextRender · 0xf94600',
      hookCode: 'HS932@f94600',
      nativeThreadId: 0x9,
      discoveredAt: discoveredAt,
    );

    expect(TexthookerService.instance.entries, isEmpty);
    expect(TexthookerService.instance.textThreads, hasLength(1));
    expect(
      TexthookerService.instance.textThreads.single.label,
      'TextRender · 0xf94600',
    );
    expect(TexthookerService.instance.textThreads.single.lineCount, 0);

    TexthookerService.instance.appendLine(
      'このように、とても素敵な性格のお方である。',
      textThreadKey: 'luna:textrender',
      textThreadLabel: 'TextRender · 0xf94600',
      nativeTextThreadId: 0x9,
      receivedAt: discoveredAt.add(const Duration(seconds: 1)),
    );
    expect(TexthookerService.instance.textThreads.single.lineCount, 1);

    TexthookerService.instance.clear();
    expect(TexthookerService.instance.textThreads, isEmpty);
  });

  test('text-bearing threads sort before freshly-discovered 0-line threads',
      () {
    final DateTime base = DateTime(2026, 7, 26, 12);
    // 有台词的线程先出现（较早）……
    TexthookerService.instance.appendLine(
      '当前台词',
      textThreadKey: 'luna:voice',
      textThreadLabel: 'KiriKiriZ · 0xa74600',
      receivedAt: base,
    );
    // ……随后一条 ThreadCreate 把 0 行线程的 latestAt 顶到更晚（旧排序会让它排最前）。
    TexthookerService.instance.registerTextThread(
      key: 'luna:empty',
      label: 'TextRender · 0x9c7c571',
      discoveredAt: base.add(const Duration(seconds: 5)),
    );

    final List<TexthookerTextThread> threads =
        TexthookerService.instance.textThreads;
    expect(threads, hasLength(2));
    expect(threads.first.key, 'luna:voice',
        reason: '有台词的线程必须排在刚发现的 0 行线程之前，即便后者 latestAt 更晚');
    expect(threads.last.key, 'luna:empty');
  });

  test('threads with audio sort ahead of text-only threads of equal recency',
      () {
    final DateTime at = DateTime(2026, 7, 26, 13);
    TexthookerService.instance.appendLine(
      '无音频行',
      textThreadKey: 'luna:textonly',
      textThreadLabel: 'A',
      receivedAt: at,
    );
    final TexthookerLineEntry withAudio = TexthookerService.instance.appendLine(
      '有音频行',
      textThreadKey: 'luna:withaudio',
      textThreadLabel: 'B',
      receivedAt: at,
    )!;
    TexthookerService.instance.updateLineAudio(
      withAudio.id,
      status: TexthookerLineAudioStatus.matched,
    );

    expect(TexthookerService.instance.textThreads.first.key, 'luna:withaudio');
  });

  group('foldRepeatedTextForPreview', () {
    test('collapses a short unit repeated many times', () {
      expect(foldRepeatedTextForPreview('アトリアトリアトリ'), 'アトリ');
      expect(foldRepeatedTextForPreview('文本文本'), '文本');
      expect(foldRepeatedTextForPreview('ABAB'), 'AB');
    });

    test('collapses long runs of one grapheme', () {
      expect(foldRepeatedTextForPreview('靴靴靴靴靴'), '靴');
      // 混合垃圾：长游程收成单字，可读性大幅提升（不追求完美复原）。
      expect(
        foldRepeatedTextForPreview('靴靴靴靴靴ををを脱脱脱'),
        '靴を脱',
      );
    });

    test('leaves normal Japanese sentences untouched', () {
      const String s = '靴を脱いで裸足になったアトリの足の間を魚が泳いでいく。';
      expect(foldRepeatedTextForPreview(s), s);
    });

    test('empty / single grapheme are returned as-is', () {
      expect(foldRepeatedTextForPreview(''), '');
      expect(foldRepeatedTextForPreview('あ'), 'あ');
    });
  });

  group('collapseTexthookerPreview', () {
    test('folds repetition before whitespace collapse and truncation', () {
      expect(collapseTexthookerPreview('アトリアトリアトリ'), 'アトリ');
    });

    test('truncates by grapheme with an ellipsis', () {
      final String long = 'あ' * 50;
      final String preview = collapseTexthookerPreview(long, maxCharacters: 40);
      // 折叠后 'あ'*50 的长游程收成单字 'あ'，不再触发截断。
      expect(preview, 'あ');
    });

    test('a non-repeating long line is truncated to maxCharacters + ellipsis',
        () {
      const String base = '零一二三四五六七八九';
      final String long = base * 5; // 50 graphemes, no run/period match
      final String preview = collapseTexthookerPreview(long, maxCharacters: 40);
      // base*5 恰为周期串 → 折叠成 base（10 字），因此不截断。
      expect(preview, base);
    });
  });

  group('assignThreadDisplayLabels', () {
    TexthookerTextThread thread(String key, String label) =>
        TexthookerTextThread(
          key: key,
          label: label,
          lineCount: 0,
          latestAt: DateTime(2026, 7, 26),
        );

    test('unique labels are returned unchanged', () {
      final Map<String, String> labels =
          assignThreadDisplayLabels(<TexthookerTextThread>[
        thread('a', 'KiriKiriZ · 0xa74600'),
        thread('b', 'TextRender · 0x9c7c571'),
      ]);
      expect(labels['a'], 'KiriKiriZ · 0xa74600');
      expect(labels['b'], 'TextRender · 0x9c7c571');
    });

    test('duplicate labels get #N suffixes in input order', () {
      final Map<String, String> labels =
          assignThreadDisplayLabels(<TexthookerTextThread>[
        thread('a', 'TextRender · 0x9c7c571'),
        thread('b', 'TextRender · 0x9c7c571'),
        thread('c', 'TextRender · 0x9c7c571'),
      ]);
      expect(labels['a'], 'TextRender · 0x9c7c571 #1');
      expect(labels['b'], 'TextRender · 0x9c7c571 #2');
      expect(labels['c'], 'TextRender · 0x9c7c571 #3');
    });
  });

  test('current session thread catalog excludes stale process-bound candidates',
      () {
    final DateTime oldSession = DateTime(2026, 7, 26, 12);
    final DateTime currentSession = oldSession.add(const Duration(hours: 1));
    TexthookerService.instance.registerTextThread(
      key: 'luna:old-textrender',
      label: 'TextRender · 0x9c7c571',
      nativeThreadId: 0x10,
      discoveredAt: oldSession,
    );
    TexthookerService.instance.appendLine(
      '旧会话台词',
      textThreadKey: 'luna:old-textrender',
      textThreadLabel: 'TextRender · 0x9c7c571',
      nativeTextThreadId: 0x10,
      receivedAt: oldSession.add(const Duration(seconds: 1)),
    );
    TexthookerService.instance.registerTextThread(
      key: 'luna:current-textrender',
      label: 'TextRender · 0x9c7c571',
      nativeThreadId: 0x20,
      discoveredAt: currentSession,
    );

    final List<TexthookerTextThread> current =
        TexthookerService.instance.textThreadsSince(currentSession);
    expect(current, hasLength(1));
    expect(current.single.key, 'luna:current-textrender');
    expect(current.single.nativeThreadId, 0x20);
    expect(current.single.lineCount, 0,
        reason: '当前 TextRender 尚无输出时仍可选，但不得借旧进程的历史行');
  });

  test('all-thread projection folds only simultaneous cross-thread duplicates',
      () {
    final DateTime at = DateTime(2026, 7, 27, 10);
    final TexthookerLineEntry first = TexthookerService.instance.appendLine(
      '同一句台词',
      source: TexthookerLineSource.engineHook,
      hookTimestampMs: 123000,
      textThreadKey: 'luna:kiri-a',
      receivedAt: at,
    )!;
    TexthookerService.instance.appendLine(
      '同一句台词',
      source: TexthookerLineSource.engineHook,
      hookTimestampMs: 123008,
      textThreadKey: 'luna:kiri-b',
      receivedAt: at.add(const Duration(milliseconds: 8)),
    );
    final TexthookerLineEntry legitimateRepeat =
        TexthookerService.instance.appendLine(
      '同一句台词',
      source: TexthookerLineSource.engineHook,
      hookTimestampMs: 125000,
      textThreadKey: 'luna:kiri-a',
      receivedAt: at.add(const Duration(seconds: 2)),
    )!;

    expect(TexthookerService.instance.entries, hasLength(3),
        reason: '底层逐行身份不能丢，线程选择和音频状态仍需各自的原始行');
    expect(
      collapseParallelTextThreadDuplicates(
        TexthookerService.instance.entries,
      ).map((TexthookerLineEntry entry) => entry.id),
      <String>[first.id, legitimateRepeat.id],
      reason: '只折叠同一渲染瞬间、不同 Hook 线程双写的那一份',
    );
  });

  test('同标签文本线程补可区分后缀，唯一标签保持原样', () {
    // 用户实拍：下拉里 6 条线程全叫 `CodeX · 0x459f50`——同一 hook 的并行线程只在
    // ctx/ctx2 上不同，而 ctx 没透出到 Dart，标签完全撞车，只能靠行数猜。
    final DateTime now = DateTime(2026, 7, 27, 12);
    final List<TexthookerTextThread> threads = <TexthookerTextThread>[
      TexthookerTextThread(
        key: 'luna:1a2b3c4d',
        label: 'CodeX · 0x459f50',
        lineCount: 160,
        latestAt: now,
      ),
      TexthookerTextThread(
        key: 'luna:99ff00e1',
        label: 'CodeX · 0x459f50',
        lineCount: 2,
        latestAt: now,
      ),
      TexthookerTextThread(
        key: 'luna:5566',
        label: 'GetGlyphOutlineA · 0x755ebf10',
        lineCount: 7,
        latestAt: now,
      ),
    ];
    final List<TexthookerTextThread> disambiguated =
        TexthookerService.disambiguateThreadLabels(threads);
    expect(disambiguated[0].label, 'CodeX · 0x459f50 · #3c4d');
    expect(disambiguated[1].label, 'CodeX · 0x459f50 · #00e1');
    expect(
      disambiguated[2].label,
      'GetGlyphOutlineA · 0x755ebf10',
      reason: '不重名的线程不加后缀噪音',
    );
    // key / 行数等身份字段不得被改写。
    expect(disambiguated.map((t) => t.key).toList(),
        threads.map((t) => t.key).toList());
    expect(disambiguated[0].lineCount, 160);
  });
}

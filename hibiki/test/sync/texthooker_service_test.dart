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
        backend: 'paired_voice_ogg',
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
}

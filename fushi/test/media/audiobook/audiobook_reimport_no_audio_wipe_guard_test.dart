/// BUG-1678 源码守卫：重新导入路径不得毁掉用户已有的音频。
///
/// 行为层的断言在 `packages/fushi_audio/test/audiobook/
/// audiobook_reimport_audio_survival_test.dart`（保留集真的保留、整行 upsert 真的
/// 会清列）。这里守的是**接线**——两条只有跑真对话框才能触发、单测够不着的路径：
///
/// 1. 清持久目录时必须带保留集。导入的源文件本身可能就落在持久目录内（「换字幕、
///    音频不变」就是把已持久化的路径原样再喂一遍），无条件清目录会先删源文件，
///    复制循环再去读它就抛 FileSystemException：音频没了，库里还指着不存在的路径。
/// 2. 写 audiobooks 行必须以现有行为基线（`Audiobook.cloneOf`）。upsert 是整行
///    覆盖，凭空造的记录会把本次没碰的列一起清空。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 扫描面用列举而不是全树遍历：这几条是「先清目录再复制」这个形状的全部落点，
/// 新增落点应当同时加进这份清单（清单本身就是这个不变式的文档）。
const List<String> _persistDirWriters = <String>[
  'lib/src/media/audiobook/audiobook_import_dialog.dart',
  'lib/src/media/audiobook/audiobook_alignment_service.dart',
  'lib/src/media/audiobook/book_import_dialog.dart',
];

/// 取 `cleanAudioFiles(` 之后到配对右括号为止的实参文本。
List<String> _cleanAudioFilesArgs(String code) {
  const String marker = 'cleanAudioFiles(';
  final List<String> args = <String>[];
  int from = 0;
  while (true) {
    final int idx = code.indexOf(marker, from);
    if (idx < 0) return args;
    int depth = 1;
    int i = idx + marker.length;
    final StringBuffer buf = StringBuffer();
    while (i < code.length && depth > 0) {
      final String ch = code[i];
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (depth > 0) buf.write(ch);
      i++;
    }
    args.add(buf.toString());
    from = i;
  }
}

void main() {
  test('every persist-dir cleanup passes a keep set (BUG-1678)', () {
    for (final String rel in _persistDirWriters) {
      final File src = File(rel);
      expect(src.existsSync(), isTrue,
          reason: '$rel 必须存在（相对 fushi/ 包根）；文件搬家时同步更新清单');
      final List<String> calls = _cleanAudioFilesArgs(src.readAsStringSync());
      expect(calls, isNotEmpty, reason: '$rel 不再清持久目录？清单过期了，重新核对本不变式的落点');
      for (final String args in calls) {
        expect(args.contains('keep:'), isTrue,
            reason: '$rel 的 cleanAudioFiles 少了保留集：本次导入的源文件若落在持久'
                '目录内会被先删掉，随后复制时读不到而中止，用户的音频就此丢失');
      }
    }
  });

  test('the audiobook row is written from an existing baseline (BUG-1678)', () {
    final File src =
        File('lib/src/media/audiobook/audiobook_import_dialog.dart');
    final String code = src.readAsStringSync();

    final int seedIdx = code.indexOf('Audiobook.cloneOf(');
    expect(seedIdx, greaterThanOrEqualTo(0),
        reason: 'upsertAudiobook 整行覆盖：不以现有行为基线，换字幕会把 '
            'audioPaths/audioRoot 一起清空');

    final int saveIdx = code.indexOf('saveAudiobook(audiobook)');
    expect(saveIdx, greaterThan(seedIdx), reason: '基线必须在写入之前取');

    // 基线只有真读了库才成立；凭空 new 一个再 upsert 就是这条 bug 本身。
    expect(code.contains('findByBookKey(widget.bookKey)'), isTrue,
        reason: '基线必须来自 repo 里的现有行，不能靠对话框自己的缓存字段猜');
  });
}

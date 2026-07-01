import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-1031）：有声书「导入音频」入口不得再有「选目录 → 扫整目录全部音频
/// 一股脑塞进同一本书」的行为。
///
/// 用户报告：「我导入文件夹书籍，他把一系列的音频全弄到一本书了」。根因是
/// [AudiobookImportDialog] 旧的 directory mode——`_pickAudioDir` 让用户指向一个目录，
/// 导入时 `srcDir.list()` 把该目录下所有音频文件全部 addAll 进同一本书。
///
/// 修复：删掉目录选择入口，只保留「选文件」多选。真正的多段章节有声书（一本书 N 个
/// 章节音频）仍由用户经「选文件」显式多选表达——多段有声书语义完好，不被砍成单文件。
///
/// 这条扫描守卫钉住「目录吞并」不被回归引回，使「不再扫整目录 addAll」成为编译期契约。
void main() {
  String read(String path) => File(path).readAsStringSync();

  const String dialog = 'lib/src/media/audiobook/audiobook_import_dialog.dart';

  test('AudiobookImportDialog 不再提供「选目录」音频输入入口', () {
    final String src = read(dialog);

    expect(
      src.contains('Future<void> _pickAudioDir('),
      isFalse,
      reason: '「选目录」音频输入入口 _pickAudioDir 必须删除——它会让用户指向目录后'
          '把整目录音频全弄进一本书（TODO-1031）',
    );
    expect(
      src.contains('pickRealDirectoryPath('),
      isFalse,
      reason: '音频来源不得再经目录选择器 pickRealDirectoryPath 取整目录',
    );
    // 音频来源行只保留一个「选文件」按钮的 tooltip，不再有「选目录」按钮。
    expect(
      src.contains('tooltip: t.srt_import_pick_audio_dir'),
      isFalse,
      reason: '音频来源行不得再渲染「选目录」按钮',
    );
  });

  test('AudiobookImportDialog 导入时不再扫整目录 addAll 全部音频', () {
    final String src = read(dialog);

    // 老的 folder-slurp 分支：`Directory(_audioDir!)` + `srcDir.list()`。
    expect(
      src.contains('srcDir.list()'),
      isFalse,
      reason: '导入不得再 srcDir.list() 扫整目录把所有音频 addAll 进同一本书'
          '（用户抱怨「一系列音频全弄到一本」的根因，TODO-1031）',
    );
    expect(
      RegExp(r'Directory\(_audioDir!\)').hasMatch(src),
      isFalse,
      reason: '导入不得再从 _audioDir 目录派生要复制的音频文件列表',
    );
  });

  test('AudiobookImportDialog 仍保留「选文件」多选（多段章节有声书不被破坏）', () {
    final String src = read(dialog);

    expect(
      src.contains('Future<void> _pickAudioFiles('),
      isTrue,
      reason: '「选文件」多选入口必须保留，否则多段章节有声书无法导入',
    );
    // _pickAudioFiles 里的 file picker 必须仍是多选：一本多段有声书要能一次选 N 个
    // 章节文件。切出方法体断言其 allowMultiple: true。
    final int start = src.indexOf('Future<void> _pickAudioFiles(');
    expect(start, isNonNegative);
    final int end = src.indexOf('\n  Future<', start + 1);
    final String body =
        end >= 0 ? src.substring(start, end) : src.substring(start);
    expect(
      RegExp(r'allowMultiple:\s*true').hasMatch(body),
      isTrue,
      reason: '「选文件」必须 allowMultiple: true——多段章节有声书需一次选多个章节文件，'
          '不得因 TODO-1031 砍成单文件而破坏多段有声书语义',
    );
  });
}

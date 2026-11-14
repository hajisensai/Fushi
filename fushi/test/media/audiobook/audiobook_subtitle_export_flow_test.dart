import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_subtitle_export_flow.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

/// 播放页「导出当前字幕」（反馈 iUtGmIlZiD）的存盘流程：默认文件名、起始目录、写出的
/// 正文、取消与失败。平台保存框经 `saveFilePicker` 注入。
AudioCue _cue(int file, int start, int end, String text) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'c.xhtml'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = file;

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('subtitle_export_flow_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('默认文件名：有本地音频取首个音频同名 .srt，没有取书名', () {
    expect(
      audiobookSubtitleExportFileName(
        audioPaths: <String>[p.join('x', '四つ子ぐらし.m4b')],
        title: '书名',
      ),
      '四つ子ぐらし.srt',
    );
    expect(
      audiobookSubtitleExportFileName(
        audioPaths: const <String>[],
        title: '书名',
      ),
      '书名.srt',
    );
  });

  test('桌面：保存框给出默认名与音频所在目录，写出单时间轴 SRT', () async {
    final String audio = p.join(tmp.path, 'book.m4b');
    File(audio).writeAsBytesSync(<int>[0]);
    final String target = p.join(tmp.path, 'out.srt');
    String? askedName;
    String? askedDir;
    final bool ok = await runAudiobookSubtitleExport(
      cues: <AudioCue>[_cue(0, 1000, 2000, '二'), _cue(0, 0, 900, '一')],
      audioPaths: <String>[audio],
      title: '书名',
      desktop: true,
      saveFilePicker:
          ({
            required String fileName,
            required String? initialDirectory,
          }) async {
            askedName = fileName;
            askedDir = initialDirectory;
            return target;
          },
    );
    expect(ok, isTrue);
    expect(askedName, 'book.srt');
    expect(askedDir, tmp.path);
    expect(
      File(target).readAsStringSync(),
      '1\n00:00:00,000 --> 00:00:00,900\n一\n\n'
      '2\n00:00:01,000 --> 00:00:02,000\n二\n\n',
    );
  });

  test('桌面：取消保存框返回 false、不写文件', () async {
    final bool ok = await runAudiobookSubtitleExport(
      cues: <AudioCue>[_cue(0, 0, 900, '一')],
      audioPaths: const <String>[],
      title: '书名',
      desktop: true,
      saveFilePicker:
          ({
            required String fileName,
            required String? initialDirectory,
          }) async => null,
    );
    expect(ok, isFalse);
    expect(tmp.listSync(), isEmpty);
  });

  test('没有字幕：不弹保存框，返回 false', () async {
    bool asked = false;
    final bool ok = await runAudiobookSubtitleExport(
      cues: const <AudioCue>[],
      audioPaths: const <String>[],
      title: '书名',
      desktop: true,
      saveFilePicker:
          ({
            required String fileName,
            required String? initialDirectory,
          }) async {
            asked = true;
            return p.join(tmp.path, 'x.srt');
          },
    );
    expect(ok, isFalse);
    expect(asked, isFalse, reason: '失败要在弹保存框之前报出来');
  });
}

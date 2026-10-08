import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';

void main() {
  group('resolveOpenJTalkAssets', () {
    OpenJTalkAssets? resolve({
      Map<String, String> environment = const <String, String>{},
      Set<String> dirs = const <String>{},
      Set<String> files = const <String>{},
      Map<String, List<String>> voices = const <String, List<String>>{},
    }) => resolveOpenJTalkAssets(
      environment: environment,
      directoryExists: dirs.contains,
      fileExists: files.contains,
      listVoiceFiles: (String dir) =>
          List<String>.of(voices[dir] ?? const <String>[]),
    );

    test('Debian/Ubuntu 包的标准落点', () {
      const String dic = '/var/lib/mecab/dic/open-jtalk/naist-jdic';
      const String voice =
          '/usr/share/hts-voice/nitech-jp-atr503-m001/nitech_jp_atr503_m001.htsvoice';
      expect(
        resolve(
          dirs: <String>{dic, '/usr/share/hts-voice'},
          voices: <String, List<String>>{
            '/usr/share/hts-voice': <String>[voice],
          },
        ),
        (dictionaryDir: dic, voicePath: voice),
      );
    });

    test('多个声音时取排序后的第一个（结果稳定）', () {
      const String dic = '/usr/share/open-jtalk/dic';
      expect(
        resolve(
          dirs: <String>{dic, '/usr/share/open-jtalk/voices'},
          voices: <String, List<String>>{
            '/usr/share/open-jtalk/voices': <String>[
              '/usr/share/open-jtalk/voices/mei_normal.htsvoice',
              '/usr/share/open-jtalk/voices/mei_angry.htsvoice',
            ],
          },
        )?.voicePath,
        '/usr/share/open-jtalk/voices/mei_angry.htsvoice',
      );
    });

    test('缺辞书或缺声音都判没装', () {
      expect(
        resolve(
          dirs: <String>{'/usr/share/hts-voice'},
          voices: <String, List<String>>{
            '/usr/share/hts-voice': <String>['/usr/share/hts-voice/a.htsvoice'],
          },
        ),
        isNull,
      );
      expect(
        resolve(dirs: <String>{'/var/lib/mecab/dic/open-jtalk/naist-jdic'}),
        isNull,
      );
    });

    test('环境变量点名的路径优先；点名的不存在就不换别的', () {
      const Map<String, String> env = <String, String>{
        'FUSHI_OPEN_JTALK_DIC': '/opt/dic',
        'FUSHI_OPEN_JTALK_VOICE': '/opt/v.htsvoice',
      };
      expect(
        resolve(
          environment: env,
          dirs: <String>{
            '/opt/dic',
            '/var/lib/mecab/dic/open-jtalk/naist-jdic',
          },
          files: <String>{'/opt/v.htsvoice'},
        ),
        (dictionaryDir: '/opt/dic', voicePath: '/opt/v.htsvoice'),
      );
      expect(
        resolve(
          environment: env,
          dirs: <String>{'/var/lib/mecab/dic/open-jtalk/naist-jdic'},
          files: <String>{'/opt/v.htsvoice'},
        ),
        isNull,
      );
    });
  });

  group('isKanaOnlyText', () {
    test('假名（含长音、标点、全半角空格）', () {
      expect(isKanaOnlyText('にほんご'), isTrue);
      expect(isKanaOnlyText('コーヒー、ください。'), isTrue);
      expect(isKanaOnlyText(' ｶﾀｶﾅ '), isTrue);
    });

    test('带汉字 / 拉丁字母 / 空文本一律否', () {
      expect(isKanaOnlyText('日本語'), isFalse);
      expect(isKanaOnlyText('たべ物'), isFalse);
      expect(isKanaOnlyText('abc'), isFalse);
      expect(isKanaOnlyText('、。'), isFalse);
      expect(isKanaOnlyText('  '), isFalse);
    });
  });

  // 装了 Open JTalk 的 Linux 机器上跑真引擎：读汉字词也要产出非空 WAV。
  final bool hasOpenJTalk =
      Platform.isLinux &&
      Process.runSync('sh', <String>['-c', 'command -v open_jtalk']).exitCode ==
          0;
  test('Linux 真引擎：汉字词合成出 WAV', () async {
    final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String out = '${dir.path}/term.wav';
    final String? result = await ttsToFileDesktop(text: '日本語', outputPath: out);
    expect(result, out);
    final List<int> header = File(out).readAsBytesSync().sublist(0, 4);
    expect(String.fromCharCodes(header), 'RIFF');
  }, skip: hasOpenJTalk ? false : 'open_jtalk not installed');
}

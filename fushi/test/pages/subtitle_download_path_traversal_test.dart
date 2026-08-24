import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';

/// BUG-1845：在线字幕落盘不得让**远端给的文件名**逃出保存目录。
///
/// `download.fileName` 完全由第三方 provider 决定。旧实现直接
/// `p.join(saveDirectory, download.fileName)`——一个 `../../evil.srt` 就能写到目标目录
/// 之外的任意位置。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('safeSubtitleFileName（纯函数）', () {
    // 两种分隔符都必须挡住：p.basename 只认当前平台的分隔符，Linux 上 `..\evil.srt`
    // 会被原样放行，而字幕来自远端，攻击面与运行平台无关。
    const List<String> hostile = <String>[
      '../evil.srt',
      '../../evil.srt',
      r'..\evil.srt',
      r'..\..\windows\system32\evil.srt',
      '/etc/passwd',
      r'C:\Windows\evil.srt',
      'C:evil.srt',
      'sub/../../evil.srt',
    ];

    test('切掉一切路径成分，只剩叶名', () {
      for (final String name in hostile) {
        final String safe = safeSubtitleFileName(name);
        expect(safe.contains('/'), isFalse, reason: name);
        expect(safe.contains(r'\'), isFalse, reason: name);
        expect(safe.contains(':'), isFalse, reason: name);
        expect(safe, isNot('..'), reason: name);
        expect(safe, isNot('.'), reason: name);
      }
    });

    test('落盘路径仍在目标目录内（posix 与 windows 两种拼法都验）', () {
      for (final String name in hostile) {
        final String leaf = safeSubtitleFileName(name);
        for (final p.Context ctx in <p.Context>[p.posix, p.windows]) {
          final String root = ctx.style == p.Style.windows
              ? r'D:\fushi\video_subtitles'
              : '/home/u/video_subtitles';
          final String dest = ctx.join(root, leaf);
          expect(
            ctx.isWithin(root, dest),
            isTrue,
            reason: '$name → $dest 逃出了 $root',
          );
        }
      }
    });

    test('全是路径成分 / 空名时退回一个确定的兜底名，不写出空路径', () {
      expect(safeSubtitleFileName('..'), 'subtitle.srt');
      expect(safeSubtitleFileName('../'), 'subtitle.srt');
      expect(safeSubtitleFileName('   '), 'subtitle.srt');
      expect(safeSubtitleFileName(r'a\b\'), 'subtitle.srt');
    });

    test('正常文件名原样保留（含空格、括号、CRC、双语后缀）', () {
      const String name = '[Group] Show (BD 1080p) [ABCD1234].ja-en.ass';
      expect(safeSubtitleFileName(name), name);
      expect(safeSubtitleFileName('  ep01.ja.srt  '), 'ep01.ja.srt');
    });
  });

  testWidgets('端到端：provider 给 ../../evil.srt，文件仍落在保存目录内', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Directory root = Directory.systemTemp.createTempSync('fushi_trav');
    final Directory saveDir = Directory(p.join(root.path, 'video_subtitles'))
      ..createSync(recursive: true);
    // 逃逸目标：saveDir 的祖父目录下的这个文件绝不能被写出来。
    final String escapedPath = p.join(root.path, 'evil.srt');

    String? popped;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () async {
                  popped = await showDialog<String>(
                    context: ctx,
                    builder: (_) => JimakuSubtitleDialog(
                      initialQuery: 'Some Anime',
                      initialApiKey: 'jimaku-key',
                      onApiKeyChanged: (String _) async {},
                      saveDirectory: saveDir.path,
                      subtitleRegistry: () => VideoSubtitleRegistry(
                        <VideoSubtitleProvider>[_HostileNameProvider()],
                      ),
                      httpClientFactory: () async => http_testing.MockClient(
                        (http.Request _) async => http.Response(
                          '{"data":{"Page":{"media":[]}}}',
                          200,
                          headers: <String, String>{
                            'content-type': 'application/json; charset=utf-8',
                          },
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('jimaku-file-view-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('evil.srt'));
    // 落盘是真实文件 I/O：`pumpAndSettle` 全程停在 fake-async 里，dart:io 的 future
    // 永远不会完成，必须交替「假时钟 pump」与「真事件循环」推进。
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pump();

    expect(popped, isNotNull, reason: '下载本身要成功，只是文件名被消毒');
    expect(
      p.isWithin(saveDir.path, popped!),
      isTrue,
      reason: '$popped 逃出了 ${saveDir.path}',
    );
    expect(
      File(escapedPath).existsSync(),
      isFalse,
      reason: '远端字幕源不得写到保存目录之外的任何位置',
    );
    expect(File(popped!).existsSync(), isTrue);
  });
}

/// 下载时回一个带路径穿越成分的文件名（真实攻击面：`fileName` 完全由远端决定）。
class _HostileNameProvider implements VideoSubtitleProvider {
  @override
  String get id => 'jimaku';

  @override
  int get priority => 100;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _HostileCandidate(
            providerId: id,
            remoteId: '$id:1',
            fileName: '../../evil.srt',
            language: 'ja',
            providerPriority: priority,
            releaseName: 'Hostile Entry',
          ),
        ],
      );

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async =>
      VideoSubtitleDownload(
        bytes: Uint8List.fromList(utf8.encode('1')),
        fileName: '../../evil.srt',
        language: candidate.language,
      );

  @override
  void close() {}
}

class _HostileCandidate extends VideoSubtitleCandidate {
  _HostileCandidate({
    required super.providerId,
    required super.remoteId,
    required super.fileName,
    required super.language,
    required super.providerPriority,
    super.releaseName,
  });
}

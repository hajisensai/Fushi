// BUG-5543（反馈 WNUWVgsr6Q）：Windows 上 YouTube 交给 Fushi 播放走网页档，设置面板「字幕」
// 分类曾只列站点轨——「导入字幕文件」和「副字幕」区都没了。这里直接构建网页档的轨列表
// [VideoWebSubtitleTrackRows]，钉住两个入口都在、点了落到对的回调。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show
        VideoWebSiteSubtitleRow,
        VideoWebSubtitleTrackRow,
        VideoWebSubtitleTrackRows;
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';

const String _dir = 'lib/src/pages/implementations/video_fushi';

class _Calls {
  final List<bool> imports = <bool>[];
  final List<String?> primary = <String?>[];
  final List<String> primarySite = <String>[];
  final List<String?> secondary = <String?>[];
  final List<String> secondarySite = <String>[];
}

Future<_Calls> _pump(
  WidgetTester tester, {
  String? activeKey,
  String? secondaryKey,
  bool importEnabled = true,
}) async {
  final _Calls calls = _Calls();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VideoWebSubtitleTrackRows(
            tracks: const <VideoWebSubtitleTrackRow>[
              (key: 'v1|ja', label: '日语 (自动生成)'),
              (key: 'v1|download:mine.srt', label: 'mine.srt'),
            ],
            siteTracks: const <VideoWebSiteSubtitleRow>[
              (id: 'en', label: 'English', status: 'site', selected: false),
            ],
            secondarySiteTracks: const <VideoWebSiteSubtitleRow>[
              (id: 'en', label: 'English', status: 'site', selected: false),
            ],
            activeKey: activeKey,
            secondaryKey: secondaryKey,
            importEnabled: importEnabled,
            onImport: calls.imports.add,
            onSelect: calls.primary.add,
            onSelectSite: calls.primarySite.add,
            onSelectSecondary: calls.secondary.add,
            onSelectSecondarySite: calls.secondarySite.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return calls;
}

void main() {
  testWidgets('网页档字幕面板有「导入字幕文件」，点了按主字幕导入', (WidgetTester tester) async {
    final _Calls calls = await _pump(tester, activeKey: 'v1|ja');
    final Finder import = find.byKey(
      const ValueKey<String>('video-web-subtitle-import'),
    );
    expect(import, findsOneWidget);
    await tester.tap(import);
    expect(calls.imports, <bool>[false]);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-web-subtitle-v1|download:mine.srt'),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-site-subtitle-en')),
    );
    expect(calls.primary, <String?>['v1|download:mine.srt']);
    expect(calls.primarySite, <String>['en']);
  });

  testWidgets('网页档字幕面板有「副字幕」区：关闭 / 导入 / 已有轨 / 站点轨都能选', (
    WidgetTester tester,
  ) async {
    final _Calls calls = await _pump(tester, activeKey: 'v1|ja');
    final Finder section = find.byKey(
      const ValueKey<String>('video-web-secondary-subtitles'),
    );
    expect(section, findsOneWidget);
    await tester.tap(section);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-secondary-subtitle-import')),
    );
    expect(calls.imports, <bool>[true]);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-secondary-subtitle-v1|ja')),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-web-secondary-site-subtitle-en'),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-secondary-subtitle-off')),
    );
    expect(calls.secondary, <String?>['v1|ja', null]);
    expect(calls.secondarySite, <String>['en']);
    expect(calls.primary, isEmpty, reason: '副字幕区的点选不动主字幕');
  });

  testWidgets('字幕加载中两个导入入口都灰掉', (WidgetTester tester) async {
    final _Calls calls = await _pump(tester, importEnabled: false);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-subtitle-import')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-secondary-subtitles')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-web-secondary-subtitle-import')),
    );
    expect(calls.imports, isEmpty);
  });

  test('宿主页接线：面板、拖放、副字幕层都走网页档的轨', () {
    final String subtitle = File('$_dir/subtitle.part.dart').readAsStringSync();
    final String web = File('$_dir/web_source.part.dart').readAsStringSync();
    expect(
      compactCode(methodBody(web, 'Widget _buildWebSubtitleTrackRows(')),
      contains('returnVideoWebSubtitleTrackRows('),
    );
    // 拖放 / 工作台下载等按路径导入：网页档不再因没有本机视频路径早退。
    final String importOuter = compactCode(
      methodBody(subtitle, 'Future<void> _importExternalSubtitle('),
    );
    expect(
      importOuter,
      contains('if(!_webMode&&_currentVideoPath==null)return;'),
    );
    expect(
      importOuter,
      contains('_importWebSubtitleFile(srcPath,secondary:false)'),
    );
    // 副字幕层与主轨同一次重选得出，在主轨的重灌闸门之前灌（主轨不变时副层照样能换）。
    final String reselect = compactCode(
      methodBody(web, 'void _reselectWebTrack('),
    );
    final int secondary = reselect.indexOf(
      'if(r.secondaryReload)controller.setSecondaryCues(r.secondaryCues);',
    );
    expect(secondary, greaterThanOrEqualTo(0));
    expect(secondary, lessThan(reselect.indexOf('if(!r.reload)return;')));
  });
}

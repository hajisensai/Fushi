import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/pages/implementations/video_import_page.dart';
import 'package:fushi/src/pages/implementations/video_library_drop_port.dart';

import '../helpers/source_guard.dart';

/// 视频导入视图（导入稿 v2「3. 视频」）：
/// - BUG-4857（IM2）：导入视图画着拖放虚线与悬停态，祖先链却没有落点；现在整页
///   落点经 [VideoLibraryDropPort] 交给视频库页现有的分发；
/// - BUG-4858（IM10）：「网络共享」说明从本域真实传输派生；
/// - IM18：刮削三件套两套设计系统都登记进浮动顶栏。
Future<void> _noop() async {}

ImportSurfaceSpec _spec({bool busy = false, bool cdNote = false}) =>
    buildVideoImportSpec(
      onImportVideo: _noop,
      onImportFolder: _noop,
      onImportIptv: _noop,
      onAddNetworkSource: _noop,
      busy: busy,
      showAudioCdNote: cdNote,
      onDrop: (List<String> paths, Offset at) {},
    );

void main() {
  group('buildVideoImportSpec', () {
    test('方式按规范顺序：视频 → 文件夹 → IPTV → 网络', () {
      final ImportSurfaceSpec spec = _spec();
      expect(spec.tone, ImportTone.cyan);
      expect(
        spec.methods.map((ImportMethod m) => m.kind).toList(),
        <ImportMethodKind>[
          ImportMethodKind.primary,
          ImportMethodKind.folder,
          ImportMethodKind.iptv,
          ImportMethodKind.network,
        ],
      );
    });

    test('BUG-4858：网络说明含本域真实传输（SFTP · WebDAV · AList，无 FTP）', () {
      final ImportMethod network = _spec().methods.last;
      expect(network.description, contains('SFTP · WebDAV · AList'));
      expect(network.description, isNot(contains('· FTP')));
      expect(importNetworkTransportsSummary('video'), 'SFTP · WebDAV · AList');
    });

    test('BUG-4857：spec 带落点（整页收拖放）', () {
      expect(_spec().onDrop, isNotNull);
    });

    test('音频 CD 附注只在能抓轨的平台给', () {
      expect(_spec().methods[1].note, isNull);
      expect(_spec(cdNote: true).methods[1].note, isNotNull);
    });

    test('忙时文件夹 / 网络两个碰来源区的方式禁用，对话框方式照常', () {
      final ImportSurfaceSpec spec = _spec(busy: true);
      final Map<String, bool> enabled = <String, bool>{
        for (final ImportMethod m in spec.methods) m.id: m.enabled,
      };
      expect(enabled, <String, bool>{
        'video': true,
        'folder': false,
        'iptv': true,
        'network': false,
      });
    });

    test('格式从扩展名集合派生：视频 / 播放列表 / 串流三组', () {
      final ImportSurfaceSpec spec = _spec();
      expect(spec.formatGroups, hasLength(3));
      expect(spec.formatGroups[1].labels, containsAll(<String>['M3U8', 'M3U']));
      expect(spec.formatGroups[2].labels, <String>['HTTP']);
    });
  });

  group('VideoLibraryDropPort（BUG-4857）', () {
    test('转交给挂上的处理函数；只撤自己挂的那一个', () async {
      final VideoLibraryDropPort port = VideoLibraryDropPort();
      final List<List<String>> got = <List<String>>[];
      void a(List<String> paths, Offset at) => got.add(paths);
      void b(List<String> paths, Offset at) {}
      await port.drop(<String>['x.mkv'], Offset.zero);
      expect(got, isEmpty, reason: '没有库页时什么都不做');
      port.attach(a);
      await port.drop(<String>['x.mkv'], Offset.zero);
      expect(got, <List<String>>[
        <String>['x.mkv'],
      ]);
      port.detach(b);
      expect(port.attached, isTrue, reason: '别人的 detach 不撤我');
      port.detach(a);
      expect(port.attached, isFalse);
    });
  });

  group('接线守卫', () {
    final String shell = maskComments(
      File(
        'lib/src/pages/implementations/video_library_shell.dart',
      ).readAsStringSync(),
    );
    final String home = maskComments(
      File(
        'lib/src/pages/implementations/home_video_page.dart',
      ).readAsStringSync(),
    );
    final String page = maskComments(
      File(
        'lib/src/pages/implementations/video_import_page.dart',
      ).readAsStringSync(),
    );

    test('BUG-4857：壳把同一个端口交给库页与导入视图', () {
      expect(shell, contains('importDropPort: _importDropPort'));
      expect(shell, contains('VideoImportPage('));
      expect(shell, contains('onDrop: _importDropPort.drop'));
      expect(shell, isNot(contains('MediaSourcesPage(')));
    });

    test('BUG-4857：库页挂上的处理不命中视频卡（库页此刻在 Offstage 里）', () {
      expect(
        home,
        contains('widget.importDropPort?.attach(_importSurfaceDrop)'),
      );
      expect(
        home,
        contains('widget.importDropPort?.detach(_importSurfaceDrop)'),
      );
      expect(home, contains('cardTargets: false'));
      expect(
        home,
        matches(RegExp(r'cardTargets\s*\?\s*_cardDropRegistry\.hitTest')),
      );
    });

    test('BUG-4857：拖入文件夹登记来源后，导入视图的来源色块立即重读', () {
      // 库页那一支照旧不等；导入视图那一支等落库扫描完，返回后页面 reload。
      expect(home, contains('awaitSourceChanges: true'));
      expect(
        home,
        matches(
          RegExp(
            r'if \(awaitSourceChanges\) \{\s*await adding;\s*\} else \{\s*'
            r'unawaited\(adding\);',
          ),
        ),
      );
      expect(page, contains('onDrop: widget.onDrop == null ? null : _drop'));
      expect(
        page,
        matches(
          RegExp(
            r'await onDrop\(paths, globalPosition\);\s*'
            r'if \(!mounted\) return;\s*'
            r'await _viewKey\.currentState\?\.reload\(\);',
          ),
        ),
      );
    });

    test('IM18：页头不再按 Cupertino 跳过（iOS 也能看到刮削三件套）', () {
      expect(
        page,
        isNot(contains('if (!isCupertinoPlatform(context)) _buildHeader')),
      );
      expect(page, contains('_buildHeader(busy),'));
      expect(page, contains('t.scrape_all'));
      expect(page, contains('t.video_source_scrape_tasks_open'));
      expect(page, contains('t.video_source_scrape_clear_all'));
    });
  });
}

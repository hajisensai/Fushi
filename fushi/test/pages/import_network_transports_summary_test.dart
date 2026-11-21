import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/import/import_surface_spec.dart';

import '../helpers/source_guard.dart';

/// BUG-4858（导入稿 IM10）：「添加来源 › 网络」的说明曾是写死的两条 key——视频
/// `media_source_network_subtitle_video`「WebDAV 远程库」（实际 SFTP / WebDAV /
/// AList），书 / 漫画 / 音乐共用 `media_source_network_subtitle`「SFTP / FTP /
/// WebDAV」（漏 AList，音乐还不支持 FTP）。现在说明从 [importNetworkTransports]
/// 派生，与 `_NetworkSourceFormDialog` 的协议分段同源。
void main() {
  test('各域说明与真实可选传输一致', () {
    expect(importNetworkTransportsSummary('video'), 'SFTP · WebDAV · AList');
    expect(importNetworkTransportsSummary('music'), 'SFTP · WebDAV · AList');
    expect(
      importNetworkTransportsSummary('book'),
      'SFTP · FTP · WebDAV · AList',
    );
    expect(
      importNetworkTransportsSummary('manga'),
      'SFTP · FTP · WebDAV · AList',
    );
    expect(importNetworkTransports('game'), isEmpty);
  });

  test('「添加来源」对话框的网络说明从传输派生，不再写死副标题', () {
    final String view = maskComments(
      File(
        'lib/src/pages/implementations/media_sources_view.dart',
      ).readAsStringSync(),
    );
    final int start = view.indexOf('Future<void> addSource() async {');
    expect(start, isNonNegative);
    final int end = view.indexOf('Future<void> importFolder() async {', start);
    final String addSource = view.substring(start, end);
    expect(
      addSource,
      contains('hint: importNetworkTransportsSummary(widget.mediaKind)'),
    );
    expect(view, isNot(contains('media_source_network_subtitle')));
    // 网络表单的协议分段也从同一真相源取。
    expect(view, contains('importNetworkTransports(widget.mediaKind)'));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：客户端互联视频合集连播的关键接线，防后续重构悄悄回退成「远端只认
/// host 下发的 episodes」（Phase 3 合集成员各自独立行、host 不填 episodes → 无列表无连播）。
///
/// 验证三条不变量：
///  1. 播放器 `_initRemote` 在合集模式（`_isRemoteCollection`）下用 `_remoteMembers` 建 `_episodes`。
///  2. 播放器 `_loadRemoteEpisode` 在合集模式下换的是**成员 id**（`_remoteMembers[...]`）并把
///     当前成员指针 `_activeRemoteMember` 切到目标成员（而非同 id 换 episodeIndex）。
///  3. 首页合集行把有序远端成员列表（`collectionMembers` / `remoteCollectionMembers`）传进播放器。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), true, reason: '找不到源文件：$rel');
    return f.readAsStringSync();
  }

  test('播放器 _initRemote 合集模式用成员列表建 _episodes', () {
    final String src =
        read('lib/src/pages/implementations/video_fushi_page.dart');
    expect(src.contains('bool get _isRemoteCollection'), true,
        reason: '应有合集连播模式判据 _isRemoteCollection');
    expect(
        src.contains(
            'widget.remoteCollectionMembers ?? const <RemoteVideoInfo>[]'),
        true,
        reason: '_initRemote 应从 widget 取远端合集成员列表');
    // 合集模式下用成员建 _episodes（每成员一个 _PlaylistEpisodeRef）。
    expect(
        RegExp(r'for \(final RemoteVideoInfo m in _remoteMembers\)')
            .hasMatch(src),
        true,
        reason: '合集模式应遍历 _remoteMembers 建剧集列表');
  });

  test('播放器 _loadRemoteEpisode 合集模式换成员 id + 切当前成员指针', () {
    final String src =
        read('lib/src/pages/implementations/video_fushi_page.dart');
    expect(src.contains('_activeRemoteMember = info'), true,
        reason: '换集时应把当前成员指针切到目标成员');
    expect(src.contains('streamEpisodeIndex'), true,
        reason: '合集成员各自单视频，episodeIndex 应恒 0（streamEpisodeIndex）');
    // _effectiveRemoteInfo 优先返回可变的当前成员，使断点/字幕/上报跟随成员 id。
    expect(src.contains('_activeRemoteMember ?? widget.remoteInfo'), true,
        reason: '_effectiveRemoteInfo 应优先返回当前成员');
  });

  test('首页保留有序远端成员 → 播放器的透传接线（_openRemote）', () {
    // 封面卡形态（用户拍板 2026-07-22）后合集成员不再直接渲染在库页，旧「行内
    // itemBuilder 收集有序远端成员」的调用点随横排行退役；但 _openRemote /
    // _buildRemoteVideoCard 的成员透传参数必须保留（散卡远端播放 + 后续详情页
    // 接入远端成员的既定通道），删参即回退成「远端只认 host 下发 episodes」。
    final String src =
        read('lib/src/pages/implementations/home_video_page.dart');
    expect(src.contains('remoteCollectionMembers:'), true,
        reason: '_openRemote 应把合集成员透传给 neutralizedRemote');
    expect(src.contains('List<RemoteVideoInfo>? collectionMembers'), true,
        reason: '_openRemote/_buildRemoteVideoCard 必须保留有序成员透传参数');
  });
}

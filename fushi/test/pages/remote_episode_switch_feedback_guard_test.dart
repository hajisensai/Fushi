import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2609 源码守卫：远端（视频源扩展 / 互联 / 媒体服务器）换集的反馈与失败落点。
///
/// 播放页本体在 widget 测试里起不了 libmpv，这些接线只能钉在源码上：
///  1. 远端换集先 `pause()` 旧集（扩展取流是秒到几十秒级，旧集不能继续响着播）；
///  2. 换集期间有非模态 OSD（`_remoteSwitchPhase` → `_buildRemoteSwitchOverlay`），
///     且挂在窗口 / 全屏共用的 controls Stack 上；
///  3. 取流失败把当前成员指针拨回旧集，重试落到要切的那集（`_remoteLastAttemptedEpisode`）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), true, reason: '找不到源文件：$rel');
    return f.readAsStringSync();
  }

  test('远端换集先暂停旧集再取流', () {
    final String src = read(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    );
    final int remoteBranch = src.indexOf('if (_isRemote) {');
    final int pause = src.indexOf('await _controller?.pause();', remoteBranch);
    final int load = src.indexOf(
      'await _loadRemoteEpisode(index, startIntent: intent);',
      remoteBranch,
    );
    expect(remoteBranch, greaterThanOrEqualTo(0));
    expect(pause, greaterThan(remoteBranch), reason: '远端分支应先 pause 旧集');
    expect(load, greaterThan(pause), reason: 'pause 必须在 _loadRemoteEpisode 之前');
  });

  test('换集 OSD 由 _remoteSwitchPhase 驱动并挂进共用 controls Stack', () {
    final String page = read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    final String episode = read(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    );
    final String layout = read(
      'lib/src/pages/implementations/video_fushi/layout.part.dart',
    );
    expect(
      page.contains('final ValueNotifier<_VideoLoadPhase?> _remoteSwitchPhase'),
      true,
    );
    // 阶段推进要同步进 OSD（connecting → downloadingSubtitle → buffering）。
    expect(
      page.contains(
        'if (_remoteSwitchPhase.value != null) _remoteSwitchPhase.value = phase;',
      ),
      true,
      reason: '_setLoadingPhase 应把阶段推进给换集 OSD',
    );
    expect(
      page.contains(
          'if (switching) _remoteSwitchPhase.value = _VideoLoadPhase.connecting;'),
      true,
      reason: '_loadRemoteEpisode 换集时应亮 OSD',
    );
    expect(
      page.contains('if (mounted && switching && seq == _episodeLoadSeq) {\n'
          '        _remoteSwitchPhase.value = null;'),
      true,
      reason: '只清自己这一程的 OSD，且页面已退出（notifier 已 dispose）时不再写它',
    );
    expect(episode.contains('Widget _buildRemoteSwitchOverlay()'), true);
    expect(
      episode.contains("ValueKey<String>('video-remote-switch-overlay')"),
      true,
    );
    expect(
      layout.contains('_buildRemoteSwitchOverlay(),'),
      true,
      reason: '换集 OSD 应与 auto-advance / OSD 同挂在共用 controls Stack',
    );
  });

  test('取流失败回滚当前成员指针，重试落到要切的那集', () {
    final String page = read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    expect(page.contains('int? _remoteLastAttemptedEpisode;'), true);
    expect(
      page.contains('_remoteLastAttemptedEpisode = index;'),
      true,
      reason: '_loadRemoteEpisode 应记住尝试的集',
    );
    expect(
      RegExp(
        r'widget\.sourceReview\?\.episodeIndex \?\?\s*_remoteLastAttemptedEpisode \?\?\s*widget\.initialEpisodeIndex',
      ).hasMatch(page),
      true,
      reason: '_initRemote 起播集应优先取上次尝试的集（重试落点）',
    );
    expect(
      RegExp(
        r'_activeRemoteMember =\s*_remoteMembers\[_currentEpisode\.clamp\(',
      ).hasMatch(page),
      true,
      reason: '失败时应把当前成员指针拨回旧集',
    );
  });
}

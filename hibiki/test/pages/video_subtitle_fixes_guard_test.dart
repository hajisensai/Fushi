import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for the 2026-06-08 video subtitle fix batch. media_kit cannot
/// run headless and OS-level drag/focus can't be widget-tested, so each fix
/// locks its call-site invariant in `video_hibiki_page.dart` rather than driving
/// a real player.
///
/// - BUG-130: 点击画面不暂停（media_kit 桌面 `playAndPauseOnTap` 默认 false）。
/// - BUG-131: 导入字幕后键盘失灵（加载遮罩夺焦后未归还）。
/// - BUG-132: 退出后导入字幕丢（播放列表恢复不按路径加载 app 文档目录里的导入文件）。
/// - BUG-133: 视频画面拖入字幕无反应（窗口模式缺页级拖放目标）。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();
  final String homeVideoSrc =
      File('lib/src/pages/implementations/home_video_page.dart')
          .readAsStringSync();
  final String shelfSrc =
      File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
          .readAsStringSync();

  String region(String startSig, String endSig, {String? source}) {
    final String haystack = source ?? src;
    final int start = haystack.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = haystack.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return haystack.substring(start, end);
  }

  test('BUG-130: 桌面控制条启用单击播放/暂停', () {
    final String body = region(
      'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(src.contains('playAndPauseOnTap: true'), isTrue,
        reason: '桌面单击画面必须播放/暂停，否则点画面毫无反应（BUG-130）');
    expect(body.contains('playAndPauseOnTap: true'), isTrue,
        reason: 'playAndPauseOnTap 必须设在桌面控制主题里');
  });

  test('BUG-131: 关闭字幕加载遮罩后归还焦点给视频', () {
    final String body = region(
      'void _hideSubtitleLoadingOverlay() {',
      'Future<bool> _selectSubtitleSource(',
    );
    expect(body.contains('_refocusVideo()'), isTrue,
        reason: '加载遮罩是模态对话框、会夺焦；关闭后必须主动把焦点还给 Video，'
            '否则空格等快捷键失灵（BUG-131）');
    expect(body.contains('addPostFrameCallback'), isTrue,
        reason: '应在下一帧归还焦点（让 pop 自身焦点变更先落定）');
  });

  test('BUG-132: 恢复字幕源时对导入的外挂文件按路径直接加载', () {
    final String body = region(
      'Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>',
      'SubtitleSource? _firstMatching(',
    );
    expect(body.contains('isImportedExternalSubtitlePath('), isTrue,
        reason: 'app 文档目录里的导入字幕不在剧集目录、listAllSubtitleSources 扫不到，'
            '必须按持久化的绝对路径直接加载（BUG-132）');
    expect(body.contains('File(persisted).existsSync()'), isTrue,
        reason: '按路径加载前要确认文件仍在磁盘上');
    // 该捷径必须排在同目录枚举之前。
    final int shortcut = body.indexOf('isImportedExternalSubtitlePath(');
    final int enumerate = body.indexOf('listAllSubtitleSources(');
    expect(shortcut, lessThan(enumerate),
        reason: '按路径直接加载应先于 listAllSubtitleSources 同目录枚举');
  });

  test('BUG-165: 换集时导入字幕捷径按目录归属判定（剧集同目录 sidecar 不沿用）', () {
    final String body = region(
      'Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>',
      'SubtitleSource? _firstMatching(',
    );
    // 换集分支必须改用按目录归属区分的判定，而非只看扩展名的
    // isImportedExternalSubtitlePath——否则上一集同目录 sidecar 会被原样沿用到新集。
    expect(body.contains('shouldReusePersistedSubtitleAcrossEpisode('), isTrue,
        reason: '换集（crossEpisode）时捷径必须按目录归属区分导入字幕 vs 剧集同目录 '
            'sidecar，剧集同目录 sidecar 要落回枚举按新集名重新匹配（BUG-165）');
    expect(body.contains('crossEpisode'), isTrue,
        reason: '目录归属判定只能加在换集分支，不影响单视频恢复');
    // 捷径条件仍要确认文件在磁盘上。
    expect(body.contains('File(persisted).existsSync()'), isTrue);
  });

  test('TODO-016: 字幕菜单只补入当前持久化的导入字幕源', () {
    final String menu = region(
      'Future<void> _showSubtitleSourceMenu(',
      'Future<void> _openJimakuDialog(',
    );
    expect(menu.contains('_subtitleSourcesForMenu('), isTrue,
        reason: '菜单不能只用 listAllSubtitleSources；重进后还要补入当前视频持久化的导入字幕');
    expect(
        menu.contains('currentSubtitleSource: _currentSubtitleSource'), isTrue,
        reason: '只允许把当前视频持久化的字幕源补进菜单，不能扫描历史导入目录');

    final String helper = region(
      'Future<List<SubtitleSource>> _subtitleSourcesForMenu(',
      'SubtitleSource? _firstMatching(',
    );
    expect(
        RegExp(r'listAllSubtitleSources\s*\(\s*videoPath\s*,').hasMatch(helper),
        isTrue,
        reason: '菜单基础列表仍应来自当前视频的内封轨 + 同目录 sidecar');
    expect(helper.contains('includeCurrentPersistedSubtitleForMenu('), isTrue,
        reason: '当前持久化导入字幕的补入逻辑要走可行为测试的 helper');
    expect(
        helper.contains('currentSubtitleSource: currentSubtitleSource'), isTrue,
        reason: '只有持久化值是本地可加载字幕路径时才允许补入菜单');
    expect(helper.contains('currentCues: currentCues'), isTrue,
        reason: '已有 DB cues 的重进路径必须把当前 controller cues 传给菜单 helper');
    expect(helper.contains('Directory('), isFalse,
        reason: 'TODO-016 的保守方案禁止扫描整个 video_subtitles 目录');
  });

  test('BUG-133: 视频页有页级拖放目标 + 导入去重防护', () {
    // 页级拖放目标（窗口模式可靠收拖放；内层那个供全屏用）。
    expect(src.contains('Widget _pageDropTarget('), isTrue,
        reason: '窗口模式需在页面顶层挂拖放目标，内层 media_kit controls 里的实测无反应（BUG-133）');
    final String pageDrop = region(
      'Widget _pageDropTarget(',
      'Widget _buildVideoBody(',
    );
    expect(pageDrop.contains('HibikiFileDropTarget('), isTrue);
    expect(pageDrop.contains('_handlePlaybackDrop('), isTrue);

    // 去重防护：页级 + 内层两个目标可能对同一次拖放都触发。
    final String importOuter = region(
      'Future<void> _importExternalSubtitle(',
      'Future<void> _importExternalSubtitleInner(',
    );
    expect(importOuter.contains('_subtitleImportsInFlight'), isTrue,
        reason: '同一 srcPath 在途时必须忽略二次调用，避免重复导入/重复提示（BUG-133）');
  });

  test('视频播放页拖放提示使用当前视频语义', () {
    final String playbackDrop = region(
      'void _handlePlaybackDrop(',
      'Future<void> _importExternalSubtitleInner(',
    );
    final String pageDrop = region(
      'Widget _pageDropTarget(',
      'Widget _buildVideoBody(',
    );
    expect(playbackDrop.contains('classifyDroppedFiles('), isTrue,
        reason: '播放页拖放必须先识别字幕/音频，避免把当前视频页误当成库页卡片落点');
    expect(playbackDrop.contains('_importExternalSubtitle('), isTrue,
        reason: '受支持字幕应直接导入到当前播放视频');
    expect(playbackDrop.contains('video_drop_audio_unsupported'), isTrue,
        reason: '音频文件在播放页应给出当前视频页语义，而不是要求拖到卡片');
    expect(playbackDrop.contains('drag_drop_need_card_target'), isFalse,
        reason: '播放页不能复用“某本书或某个视频”这类库页文案');
    expect(pageDrop.contains('_handlePlaybackDrop('), isTrue,
        reason: '窗口模式页级 drop target 必须走同一个播放页语义 helper');
  });

  test('被视频播放页覆盖的库页不再响应同一次文件拖放', () {
    final String videoDrop = region(
      'void _handleVideoDrop(',
      'Future<void> _openVideoImportPrefilled(',
      source: homeVideoSrc,
    );
    expect(videoDrop.contains('ModalRoute.of(context)'), isTrue);
    expect(videoDrop.contains('!route.isCurrent'), isTrue,
        reason: '播放页在上层时，视频库页不能继续弹 need-card-target SnackBar');

    final String shelfDrop = region(
      'void _handleShelfDrop(',
      'Future<void> _openBookImportPrefilled(',
      source: shelfSrc,
    );
    expect(shelfDrop.contains('ModalRoute.of(context)'), isTrue);
    expect(shelfDrop.contains('!route.isCurrent'), isTrue,
        reason: '播放页在上层时，书架页不能继续弹 need-card-target SnackBar');
  });

  test('视频通知走 mpv 式角标 OSD，不再用 Material SnackBar', () {
    expect(src.contains('void _showOsd('), isTrue,
        reason: '视频内通知应走左上角 OSD（_showOsd），取代从底部弹出遮挡控制条的 SnackBar');
    expect(src.contains('showSnackBar('), isFalse,
        reason: '视频页不应再有 showSnackBar(...) 调用——通知统一走 _showOsd（mpv 式角标）');
    final int osdStart = src.indexOf('Widget _buildOsdOverlay() {');
    expect(osdStart, greaterThanOrEqualTo(0),
        reason: 'OSD 层 _buildOsdOverlay 必须存在并挂进 controls overlay');
    final String osd = src.substring(osdStart);
    expect(osd.contains('IgnorePointer'), isTrue,
        reason: 'OSD 必须 IgnorePointer 包裹，绝不拦截点击（单击暂停/拖放/字幕查词）');
    expect(osd.contains('_osdNotifier'), isTrue,
        reason: 'OSD 监听 _osdNotifier 渲染当前消息');
  });

  test('TODO-446: 自动文本内封字幕抽取失败必须走 OSD 提示', () {
    final String applyLoad = region(
      'Future<void> _applyLoad({',
      '/// 位置持久化（controller 每秒至多一次回调）。',
    );
    expect(
      applyLoad.contains('onEmbeddedSubtitleAutoLoad:'),
      isTrue,
      reason: 'load 后后台自动抽文本内封字幕；失败不能只 debugPrint，必须回调页面显示 OSD',
    );
    expect(
      applyLoad.contains('_handleEmbeddedSubtitleAutoLoad'),
      isTrue,
      reason: '自动抽取结果应统一交给页面处理成功/失败提示',
    );

    final String handler = region(
      'void _handleEmbeddedSubtitleAutoLoad(',
      '/// 位置持久化（controller 每秒至多一次回调）。',
    );
    expect(
        handler.contains('DefaultEmbeddedSubtitleLoadStatus.loaded'), isTrue);
    expect(handler.contains('_currentSubtitleSource'), isTrue,
        reason: '自动加载成功后菜单高亮应跟随默认内封文本轨');
    expect(handler.contains('_showOsd('), isTrue, reason: '自动加载失败必须给用户可见反馈');
    expect(handler.contains('t.video_subtitle_load_failed'), isTrue,
        reason: '复用现有字幕加载失败 OSD 文案，避免静默空屏');
  });

  test('TODO-573: 「自动获取字幕(Jimaku)」入口对本地和远端视频都显示', () {
    // 入口门控不再是 `!_isRemote`，否则远端视频整条 Jimaku 入口消失（用户报：
    // 远端视频字幕轨里没有「自动获取字幕」）。改为只要能算出非空番名 query 就显示。
    final String panel = region(
      'Widget _buildSubtitleSourcesSidePanel(',
      'Widget _buildAudioTracksSidePanel(',
    );
    expect(panel.contains('if (_jimakuQuery() != null)'), isTrue,
        reason: 'Jimaku 入口门控必须按「能否算出番名 query」判定，不能用 !_isRemote '
            '把远端视频整条入口隐藏（TODO-573）');
    expect(panel.contains('if (!_isRemote && _currentVideoPath != null)'),
        isFalse,
        reason: '旧的 !_isRemote 门控会让远端视频看不到「自动获取字幕」，必须移除');
    // 入口本体仍在（标题 + 打开对话框）。
    expect(panel.contains('t.video_jimaku_fetch'), isTrue);
    expect(panel.contains('_openJimakuDialog(controller)'), isTrue);
  });

  test('TODO-573: 远端 Jimaku query 取 host 标题，下载后走内存应用', () {
    // _jimakuQuery：本地用文件名解析 series，远端用 host 下发的标题。
    final String query = region(
      'String? _jimakuQuery() {',
      'Future<void> _openJimakuDialog(',
    );
    expect(query.contains('_currentVideoPath'), isTrue,
        reason: '本地视频仍用 _currentVideoPath 的文件名解析 series');
    expect(query.contains('parseVideoFilename('), isTrue,
        reason: 'query 经 parseVideoFilename 收敛成番名 series');
    expect(query.contains('widget.remoteInfo?.title'), isTrue,
        reason: '远端无本地文件名，query 必须能回退到 host 下发的 remoteInfo.title');
    expect(query.contains('_isRemote'), isTrue,
        reason: '远端分支按 _isRemote 取标题作为 query 来源');

    // _openJimakuDialog：远端下载后内存应用（_applyRemoteSubtitle，不写本地 DB），
    // 本地仍走 _selectSubtitleSource 持久化。
    final String dialog = region(
      'Future<void> _openJimakuDialog(',
      'Future<void> _pickAndImportSubtitle(',
    );
    expect(dialog.contains('_jimakuQuery()'), isTrue,
        reason: '对话框 query 复用 _jimakuQuery，不再直接读 _currentVideoPath');
    expect(dialog.contains('if (_isRemote)'), isTrue,
        reason: '远端必须按 _isRemote 分流：没有本地 DB 行，不能走持久化链路');
    expect(dialog.contains('_applyRemoteSubtitle(controller, downloaded)'),
        isTrue,
        reason: '远端下载的字幕只能内存应用（_applyRemoteSubtitle），与远端「本地导入字幕」'
            '同一不落 DB 的链路（TODO-573）');
    expect(dialog.contains('_selectSubtitleSource(controller, source)'), isTrue,
        reason: '本地视频仍走 _selectSubtitleSource 持久化外挂字幕源');
    // 远端分支必须早返回，不要再落到本地持久化分支。
    final int remoteApply =
        dialog.indexOf('_applyRemoteSubtitle(controller, downloaded)');
    final int localSelect =
        dialog.indexOf('_selectSubtitleSource(controller, source)');
    expect(remoteApply, lessThan(localSelect),
        reason: '远端分支应在本地持久化分支之前并早返回');
  });
}

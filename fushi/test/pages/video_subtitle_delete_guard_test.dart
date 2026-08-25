import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 视频「字幕」分类里外挂字幕行的长按 / 右键「删除字幕文件」入口的源码守卫。
///
/// 行为住在 `_VideoFushiPageState` 的 part（`subtitle.part.dart`）里，字幕轨行由
/// State 的十几个私有字段驱动，脱离整个视频页（media_kit 播放器）无法实例化，
/// 所以按本仓惯例锁调用点不变量：
///  - 四处外挂字幕行（主 / 副 × 本地 / 远端导入）都经 `_withSubtitleFileMenu` 包装；
///  - 包装只给外挂源挂手势，内嵌轨原样返回（没有可删的东西、不给菜单）；
///  - 长按与右键都落到同一个菜单；菜单坐标经 Overlay.globalToLocal 换算（BUG-781）；
///  - 删除前经共享 FushiDestructiveConfirmDialog 二次确认并显示路径；菜单与对话框
///    都经 guardOverlay 归还焦点；
///  - 删文件后先清掉当前主 / 副字幕的 cue 与持久化指针（否则 BUG-081 落库的 cue 会
///    把已删字幕显示回来）：主字幕清回 `null` 无偏好（不是 `off:` 显式关闭——删错档
///    ≠ 不要字幕，下次起播仍要自动选 sidecar / 内嵌轨），副字幕复用既有关闭路径；
///    再从枚举 / 登记两份列表都移除（渲染是两份合并，只删一份会合回来）。
void main() {
  final String src = readVideoFushiSource();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  int count(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  test('主字幕轨行：本地列表 + 远端导入档案两处外挂行都挂上下文菜单', () {
    final String rows = region(
      'Widget _buildSubtitleTrackRows(',
      'List<Widget> _buildSecondarySubtitleRows(',
    );
    expect(count(rows, '_withSubtitleFileMenu('), 2,
        reason: '主字幕轨里有两处会出现外挂档案的行：远端 `_importedSubtitleSources` '
            '与本地 `_menuSubtitleSources`，两处都要能长按 / 右键删除');
    // 两处各自的行体紧跟在包装之后（包装的是那一行，不是别的 widget）。
    expect(
        RegExp(r'_withSubtitleFileMenu\(\s*context,\s*controller,\s*source,\s*ListTile\(')
            .allMatches(rows)
            .length,
        2,
        reason: '包装对象必须是该源自己的 ListTile 行');
  });

  test('副字幕轨行：远端导入档案 + 本地列表两处外挂行都挂上下文菜单', () {
    final String rows = region(
      'List<Widget> _buildSecondarySubtitleRows(',
      'Widget _withSubtitleFileMenu(',
    );
    expect(count(rows, '_withSubtitleFileMenu('), 2,
        reason: '副字幕轨与主字幕轨同一份可用列表（BUG-900 / BUG-1861），'
            '删除入口要对称');
  });

  test('包装器：只给外挂源挂手势，内嵌轨原样返回；长按与右键落同一菜单', () {
    final String wrap = region(
      'Widget _withSubtitleFileMenu(',
      'Future<void> _showSubtitleFileMenu(',
    );
    expect(wrap.contains('if (source.isEmbedded) return row;'), isTrue,
        reason: '内嵌轨没有磁盘档案可删，不该出现「删除字幕文件」菜单');
    expect(wrap.contains('onLongPressStart:'), isTrue, reason: '触屏靠长按');
    expect(wrap.contains('onSecondaryTapDown:'), isTrue, reason: '桌面靠右键');
    expect(
        count(wrap,
            '_showSubtitleFileMenu(context, controller, source, d.globalPosition)'),
        2,
        reason: '长按与右键必须落到同一个菜单、传手势自己报的视口坐标');
  });

  test(
      '菜单：抽取进行中不弹；坐标经 Overlay.globalToLocal 换算；'
      '唯一一项是共享 FushiPopupMenuItem；showMenu 经 guardOverlay 归还焦点', () {
    final String menu = region(
      'Future<void> _showSubtitleFileMenu(',
      'Future<void> _deleteSubtitleFile(',
    );
    expect(menu.contains('if (_subtitleLoadingShown) return;'), isTrue,
        reason: '行本身在抽取期间是 enabled: false，菜单要一致，'
            '否则能删掉正在抽取 / 解析的那个档案');
    expect(
        menu.contains('Overlay.of(context).context.findRenderObject()'), isTrue,
        reason: '菜单锚点要落在根 Navigator Overlay 坐标系');
    expect(menu.contains('overlay.globalToLocal(globalPosition)'), isTrue,
        reason: '界面大小≠100% 时视口坐标直接喂 showMenu 会偏移（BUG-781 同族）');
    expect(count(menu, 'FushiPopupMenuItem<bool>('), 1,
        reason: '菜单只有「删除字幕文件」一项，且用仓库收口的 FushiPopupMenuItem，'
            '不手搓 PopupMenuItem(Row(Icon, Text))');
    // 带左边界：`FushiPopupMenuItem<bool>(` 本身含子串 `PopupMenuItem<bool>(`，
    // 裸 contains 会假阳性红。
    expect(
        RegExp(r'(?<![A-Za-z])PopupMenuItem<bool>\(').hasMatch(menu), isFalse,
        reason: '裸 PopupMenuItem 是 md3 收口前的旧形态');
    expect(menu.contains('label: t.video_subtitle_delete,'), isTrue);
    expect(
        RegExp(r'_focusOwnership\.guardOverlay\(\s*\(\) => showMenu<bool>\(')
            .hasMatch(menu),
        isTrue,
        reason: '菜单是覆盖层、会夺焦；按 docs/agent/focus-ownership.md 用 '
            'guardOverlay 包 await 点，任何退出路径都归还焦点');
    expect(
        menu.contains('await _deleteSubtitleFile(controller, source);'), isTrue,
        reason: '选中删除项后必须进入带二次确认的删除路径');
  });

  test(
      '删除：先确认（共享销毁确认框、带路径）再删文件，再清当前主 / 副字幕，'
      '最后从两份列表移除', () {
    final String del = region(
      'Future<void> _deleteSubtitleFile(',
      'Future<void> _forgetDeletedSubtitleSelection(',
    );
    final int confirm =
        del.indexOf('t.video_subtitle_delete_confirm(path: path)');
    final int deleteFile = del.indexOf('await file.delete()');
    final int forgetPrimary =
        del.indexOf('await _forgetDeletedSubtitleSelection(controller);');
    final int offSecondary =
        del.indexOf('_selectSecondarySubtitleOff(controller)');
    final int removeEnumerated = del.indexOf(
        '_subtitleMenuSources = _subtitleMenuSources.where(notDeleted)');
    final int removeImported =
        del.indexOf('_importedSubtitleSources.where(notDeleted)');
    expect(confirm, greaterThanOrEqualTo(0),
        reason: '删磁盘文件是不可逆操作，必须二次确认并把完整路径给用户看');
    expect(del.contains('FushiDestructiveConfirmDialog('), isTrue,
        reason: '确认框用全 app 统一的 FushiDestructiveConfirmDialog，'
            '不再手搓裸 AlertDialog + TextButton');
    expect(del.contains('AlertDialog('), isFalse);
    expect(
        RegExp(r'_focusOwnership\.guardOverlay\(\s*\(\) => showAppDialog<FushiDestructiveConfirmResult>\(')
            .hasMatch(del),
        isTrue,
        reason: '对话框是覆盖层、会夺焦；guardOverlay 在任何退出路径归还焦点');
    expect(deleteFile, greaterThan(confirm), reason: '确认在删文件之前');
    // 光有对话框不够：结果必须真的门住删除（变异实测「去掉这行守卫仍绿」补的）。
    final int gate = del.indexOf('if (confirmed == null || !mounted) return;');
    expect(gate, greaterThan(confirm), reason: '确认结果要在对话框返回之后判');
    expect(gate, lessThan(deleteFile), reason: '用户取消时不得走到 file.delete()');
    expect(del.contains("'[video-playback] delete external subtitle failed"),
        isTrue,
        reason: '删除失败要留日志，占用 / 只读 / 权限才能从日志判型');
    expect(forgetPrimary, greaterThan(deleteFile),
        reason: '删掉的是当前主字幕时要清 cue + 清持久化指针（BUG-081：'
            '单视频落库的 cue 不清，重开会把已删字幕显示回来）');
    expect(del.contains('_selectSubtitleOff(controller)'), isFalse,
        reason: '主字幕不能落 off: 显式关闭哨兵——「删了个下错的字幕」≠「我不要字幕」，'
            'off: 会短路下次起播的 sidecar / 内嵌轨自动选择（TODO-818）');
    expect(del.contains('_clearRemoteSubtitle(controller)'), isFalse,
        reason: '远端同理，_clearRemoteSubtitle 也落 off: 并置 userDismissed');
    expect(offSecondary, greaterThan(deleteFile),
        reason: '副字幕没有自动选择，null 与 off: 恢复行为相同，'
            '直接复用既有 _selectSecondarySubtitleOff');
    expect(del.contains('_clearRemoteSecondarySubtitle(controller)'), isTrue,
        reason: '远端模式副字幕的关闭路径是 _clearRemoteSecondarySubtitle');
    expect(removeEnumerated, greaterThan(offSecondary),
        reason: '列表移除在清字幕之后（清理路径读的是当前源指针，不依赖列表）');
    expect(removeImported, greaterThan(removeEnumerated),
        reason: '渲染是 mergeImportedSubtitleSourcesForMenu 两份合并，'
            '只从枚举列表删、登记列表还会把它合回来');
    expect(del.contains('sameExternalSubtitlePathForMenu(source, primary)'),
        isTrue,
        reason: '判「是否当前源」用与列表高亮同一份路径归一判据');
  });

  test('清当前主字幕：落 null（无偏好）而非 off: 哨兵，三种落库形状齐全', () {
    final String forget = region(
      'Future<void> _forgetDeletedSubtitleSelection(',
      '\n  /// 弹「字幕源」菜单',
    );
    expect(forget.contains('controller.setCues(const <AudioCue>[]);'), isTrue,
        reason: '内存态 overlay cue 要清空');
    expect(forget.contains('setRemoteSubtitleSource(uid, ep, null)'), isTrue,
        reason: '远端：清回 null，下次起播恢复 host 默认字幕');
    expect(forget.contains('_remoteSubtitleUserDismissed'), isFalse,
        reason: '用户没有表达「不要字幕」，不得置 userDismissed');
    expect(forget.contains('subtitleSource: null,'), isTrue,
        reason: '单视频：cue + 指针原子写（BUG-081），指针为 null');
    expect(
        forget.contains('updateSubtitleSource(widget.bookUid, null)'), isTrue,
        reason: '播放列表：只写指针，为 null');
    expect(forget.contains('offSentinel'), isFalse,
        reason: 'off: 会短路下次起播的自动选择（TODO-818）');
    expect(forget.contains('_currentSubtitleSource = null'), isTrue);
  });
}

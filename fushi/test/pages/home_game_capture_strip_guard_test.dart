import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _extractInvocation(String source, String invocation, {int startAt = 0}) {
  final int invocationStart = source.indexOf(invocation, startAt);
  if (invocationStart < 0) return '';
  final int openParen = source.indexOf('(', invocationStart);
  if (openParen < 0) return '';

  int depth = 0;
  for (int index = openParen; index < source.length; index++) {
    switch (source[index]) {
      case '(':
        depth++;
        break;
      case ')':
        depth--;
        if (depth == 0) {
          return source.substring(invocationStart, index + 1);
        }
        break;
    }
  }
  return '';
}

int _occurrences(String source, String token) {
  int count = 0;
  int start = 0;
  while (true) {
    final int index = source.indexOf(token, start);
    if (index < 0) return count;
    count++;
    start = index + token.length;
  }
}

List<String> _libraryHeaderGuardProblems(String header) {
  final List<String> problems = <String>[];
  if (!header.contains('title: GameSectionTabs(')) {
    problems.add('missing segmented title');
  }
  // 提取完整性锚。原先由 `actions: <Widget>[` 兼任（证明括号配平提取穿过了 title
  // 走到 header 结尾、没在 title 前截断）；统计入口收敛到首页后 actions 块整块撤
  // 掉，锚点改挂 GameSectionTabs 的最后一个具名参数，继续守同一件事。
  if (!header.contains('onSelectSettings: _showSettings')) {
    problems.add('truncated header');
  }
  // 统计入口已收敛到首页 dashboard（2026-09-01），页头不得再挂。
  if (_occurrences(header, 'onTap: _openStatistics') != 0) {
    problems.add('statistics action must not appear');
  }
  // 踩坑换来、原样保留：捕获入口与下方 GameSectionTabs「工作台」分段去向完全
  // 相同，纯冗余，不得回潮到页头。
  if (_occurrences(header, 'onTap: _showMonitor') != 0) {
    problems.add('duplicate capture action');
  }
  return problems;
}

/// 源码扫描守卫（游戏库页 UX 收敛）：
///
/// 用户反馈游戏库页顶部两张大卡（「捕获工具已就绪…打开捕获工作台」/
/// 「兼容性诊断…打开诊断」）意义不明，且其导航与顶部 GameSectionTabs 页签完全
/// 冗余。改为一条紧凑会话状态带 [_CaptureStatusStrip]：只留库页独有的会话摘要，
/// 整条可点进入捕获工作台；诊断细节（序号缺口 / 端点连通）归诊断页。
///
/// 这些是「不该回潮」的结构不变式，用源码扫描锁死，防后续有人把两张大卡、
/// 显式大按钮或与页签冗余的顶部图标钮加回来。
void main() {
  final File source = File(
    'lib/src/pages/implementations/home_game_page.dart',
  );

  late final String src;

  setUpAll(() {
    expect(source.existsSync(), isTrue,
        reason: 'home_game_page.dart 应存在: ${source.path}');
    src = source.readAsStringSync();
  });

  group('游戏库页顶部收敛为紧凑会话状态带', () {
    test('两张总览大卡与横向滚动 Row 已删除', () {
      expect(src.contains('_CaptureOverviewCard'), isFalse,
          reason: '捕获总览大卡应已被状态带替代');
      expect(src.contains('_DiagnosticsOverviewCard'), isFalse,
          reason: '诊断总览大卡应已被状态带替代（诊断细节归诊断页）');
    });

    test('存在状态带且整条 onTap 进入捕获工作台', () {
      expect(src.contains('class _CaptureStatusStrip'), isTrue,
          reason: '应存在紧凑会话状态带组件');
      expect(src.contains('_CaptureStatusStrip('), isTrue, reason: '库页应挂载状态带');
      expect(src.contains('onOpen: _showMonitor'), isTrue,
          reason: '状态带点击必须走 _showMonitor（捕获工作台）');
      expect(src.contains('captureStatusKey'), isTrue,
          reason: '状态带须挂稳定 Key 供测试与焦点驱动定位');
    });

    test('库页顶部不再放与页签冗余的捕获图标钮', () {
      final int libraryStart = src.indexOf('Widget _buildLibrary(');
      expect(libraryStart, greaterThanOrEqualTo(0));
      final String header = _extractInvocation(
        src,
        'FushiPageHeader.customTitle',
        startAt: libraryStart,
      );
      expect(header, isNotEmpty, reason: '必须提取完整库页 header 调用，不能在 title 前截断');
      expect(
        _libraryHeaderGuardProblems(header),
        isEmpty,
        reason: '页头不得挂统计动作（已收敛到首页），也不得让捕获入口回潮',
      );
    });

    test('动作守卫能杀死截断、统计入口回潮与捕获入口回潮变异', () {
      final int libraryStart = src.indexOf('Widget _buildLibrary(');
      final String header = _extractInvocation(
        src,
        'FushiPageHeader.customTitle',
        startAt: libraryStart,
      );
      expect(header, isNotEmpty);

      // 播种锚从已撤掉的 `onTap: _openStatistics` 改成仍在的 title 参数——旧锚在
      // 源码里不存在时 replaceFirst 是空操作，三条变异会全变成「拿原文比原文」的
      // 空转，守卫看着绿其实什么都没杀。
      const String seed = 'title: GameSectionTabs(';
      expect(header.contains(seed), isTrue, reason: '变异播种锚必须真实存在');

      final String missingTitle = header.replaceFirst(seed, 'title: Text(');
      expect(
        _libraryHeaderGuardProblems(missingTitle),
        contains('missing segmented title'),
        reason: '把分段页签标题换掉的 mutation 必须变红',
      );

      final String truncated = header.substring(0, header.indexOf(seed));
      expect(
        _libraryHeaderGuardProblems(truncated),
        contains('truncated header'),
        reason: 'header 提取在 title 前截断的 mutation 必须变红',
      );

      final String statisticsBack = header.replaceFirst(
        seed,
        'actions: <Widget>[FushiIconButton(onTap: _openStatistics)], $seed',
      );
      expect(
        _libraryHeaderGuardProblems(statisticsBack),
        contains('statistics action must not appear'),
        reason: '把统计入口塞回页头的 mutation 必须变红',
      );

      final String duplicateCapture = header.replaceFirst(
        seed,
        'actions: <Widget>[FushiIconButton(onTap: _showMonitor)], $seed',
      );
      expect(
        _libraryHeaderGuardProblems(duplicateCapture),
        contains('duplicate capture action'),
        reason: '把捕获入口重新塞回页头的 mutation 必须变红',
      );
    });

    test('诊断细节（序号缺口 / 端点连通）不再出现在库页', () {
      expect(src.contains('endpointStatuses'), isFalse,
          reason: '端点连通数属诊断页，库页状态带不应展示');
      expect(src.contains('textGapCount'), isFalse,
          reason: '序号缺口属诊断页，库页状态带不应展示');
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 游戏库（Galgame Hook 工作台 + 游戏条目管理）的操作描述（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）。路由见
/// `ctl_game_routes.dart`：全部只在 Windows、「游戏」模块开着时可用。
///
/// 撤销形态：
/// * 条目配置（重命名 / 游玩状态 / 详情 / 启动期配置）= 快照：执行前从游戏仓储
///   读旧值（路由没有单条读接口，`game ls` 也不带这些字段），撤销经同一组写路由写回；
/// * 会话细项（线程 / 绑定窗口 / 选轨 / 排除轨 / 取音策略 / 逐句轨 / 收藏 /
///   文本处理 / 内嵌查词模式）= 快照：读路由取旧值、写路由写回；
/// * 启动 / 附着 / 结束会话 / 制卡 / 删除类 / 刮削落库 / 校准 = 不可逆，见各条说明。
List<OpDescription> describeGameOps(OpDescribeKit kit) {
  final OpAvailability Function() available = kit.all(
    <OpAvailability Function()>[_windowsOnly, kit.whenModule(ModuleId.games)],
  );
  OpDescription read(
    String id,
    String method,
    String pattern,
    String summary, [
    List<OpParam> params = const <OpParam>[],
  ]) => OpDescription(
    id: id,
    method: method,
    pattern: pattern,
    summary: summary,
    params: params,
    availability: available,
  );
  OpDescription write(
    String id,
    String method,
    String pattern,
    String summary,
    List<OpParam> params,
    OpUndo undo,
  ) => OpDescription(
    id: id,
    method: method,
    pattern: pattern,
    summary: summary,
    params: params,
    risk: OpRisk.write,
    undo: undo,
    availability: available,
  );
  OpDescription irreversible(
    String id,
    String method,
    String pattern,
    String summary, [
    List<OpParam> params = const <OpParam>[],
  ]) => OpDescription(
    id: id,
    method: method,
    pattern: pattern,
    summary: summary,
    params: params,
    risk: OpRisk.irreversible,
    availability: available,
  );

  return <OpDescription>[
    // ── 会话：启动 / 附着 / 结束 / 状态 ────────────────────────────────────
    read(
      'game.list',
      'GET',
      '/api/admin/game/games',
      'List games in the game library (id, title, exe path, whether it is '
          'running, language, play time).',
    ),
    // 不可逆：拉起用户磁盘上的外部程序并把随包 helper 注入游戏进程；没有路由能把
    // 外部进程「退回去」，所以每次都让用户确认，不让 AI 静默启动程序。
    irreversible(
      'game.launch',
      'POST',
      '/api/admin/game/launch',
      'Launch a game from the library and start text hook capture. Starts an '
          'external program and injects the bundled capture helper into it; '
          'replaces any running capture session after the user confirms.',
      const <OpParam>[
        OpParam.string(
          'id',
          description: 'Game id from game.list.',
          required: true,
        ),
        OpParam.userGate(
          'replace',
          description: 'User agreed to tear down the current capture session.',
        ),
      ],
    ),
    read(
      'game.window.list',
      'GET',
      '/api/admin/game/windows',
      'List capturable top-level windows (hwnd, pid, title; marks the bound '
          'window and the current game).',
    ),
    // 不可逆：把 helper 注入一个正在运行的外部进程，并替换当前捕获会话。
    irreversible(
      'game.attach',
      'POST',
      '/api/admin/game/attach',
      'Attach text hook capture to an already running game window (injects '
          'the capture helper into that process; replaces the current session). '
          'Give exactly one of hwnd / pid.',
      const <OpParam>[
        OpParam.integer(
          'hwnd',
          description: 'Window handle from game.window.list.',
        ),
        OpParam.integer(
          'pid',
          description:
              'Process id from game.window.list (must own one window).',
        ),
      ],
    ),
    // 不可逆：结束会话会丢掉进行中的 hook、台词缓冲与计时，没有路由能接回同一会话。
    irreversible(
      'game.stop',
      'POST',
      '/api/admin/game/stop',
      'Stop the current capture session (ends the hook, the line buffer and '
          'the play timer).',
      const <OpParam>[
        OpParam.boolean(
          'unbind',
          description: 'Also forget the bound window; default keeps it.',
        ),
      ],
    ),
    read(
      'game.status',
      'GET',
      '/api/admin/game/status',
      'Capture session status, capability stages and recent diagnostic events.',
      const <OpParam>[
        OpParam.integer(
          'events',
          description: 'How many recent events to include; default 20.',
        ),
      ],
    ),
    read(
      'game.thread.list',
      'GET',
      '/api/admin/game/threads',
      'List candidate text threads of the current session and which one is '
          'selected.',
    ),
    write(
      'game.thread.select',
      'POST',
      '/api/admin/game/threads/select',
      'Select the text thread to read dialogue from (remembered for this '
          'game), or clear the selection. Give key or clear=true.',
      const <OpParam>[
        OpParam.string('key', description: 'Thread key from game.thread.list.'),
        OpParam.boolean('clear', description: 'true = clear the selection.'),
      ],
      kit.snapshotUndo(
        read: (Map<String, String> params) async => _field(
          await kit.callRoute('GET', '/api/admin/game/threads'),
          <String>['selected'],
        ),
        write: (Map<String, String> params, Object? old) async {
          await kit.callRoute(
            'POST',
            '/api/admin/game/threads/select',
            body: old == null
                ? const <String, Object?>{'clear': true}
                : <String, Object?>{'key': old},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['selected']),
      ),
    ),
    read(
      'game.text',
      'GET',
      '/api/admin/game/text',
      'Read the latest dialogue lines captured in the current session.',
      const <OpParam>[
        OpParam.integer(
          'limit',
          description: 'How many recent lines; default 1.',
        ),
      ],
    ),
    // 不可逆：卡片写进 Anki（或改写 updateNoteId 那张），没有删卡 / 还原卡的路由。
    irreversible(
      'game.mine',
      'POST',
      '/api/admin/game/mine',
      'Create an Anki card from a captured line (exact line, screenshot and '
          'voice). Missing reading / glossary is filled from the dictionaries.',
      const <OpParam>[
        OpParam.string(
          'word',
          description: 'Target word (expression) for the card.',
          required: true,
        ),
        OpParam.string(
          'lineId',
          description: 'Line id from game.text; default the latest line.',
        ),
        OpParam.string('reading', description: 'Reading override.'),
        OpParam.string('glossary', description: 'Glossary override (HTML).'),
        OpParam.boolean(
          'lookup',
          description:
              'Fill missing fields from the dictionaries; default true.',
        ),
        OpParam.boolean(
          'allowDuplicate',
          description: 'Add even if Anki already has this word.',
        ),
        OpParam.integer(
          'updateNoteId',
          description: 'Overwrite this existing Anki note instead of adding.',
        ),
      ],
    ),

    // ── 工作台细项 ─────────────────────────────────────────────────────────
    write(
      'game.config.set',
      'PUT',
      '/api/admin/game/games/:id/config',
      'Set per-game launch options: Japanese locale emulation, Magpie window '
          'upscaling, content language. Applies on the next launch.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string(
          'locale',
          description: 'Japanese locale emulation.',
          enumValues: <String>['auto', 'on', 'off'],
        ),
        OpParam.string(
          'upscaling',
          description: 'Magpie upscaling mode.',
          enumValues: <String>['auto', 'installed_only', 'off'],
        ),
        OpParam.string(
          'language',
          description: 'Content language (BCP-47, e.g. ja).',
        ),
        OpParam.boolean(
          'clearLanguage',
          description: 'true = unset the content language.',
        ),
      ],
      _entryUndo(
        kit,
        touched: (CtlCall call) => <String>[
          if (call.body['locale'] != null) 'locale',
          if (call.body['upscaling'] != null) 'upscaling',
          if (call.body['language'] != null ||
              call.body['clearLanguage'] == true)
            'language',
        ],
        readEntry: _configFields,
        restore: (String id, Map<String, Object?> old) => kit.callRoute(
          'PUT',
          '/api/admin/game/games/:id/config',
          params: <String, String>{'id': id},
          body: <String, Object?>{
            for (final MapEntry<String, Object?> e in old.entries)
              if (e.key == 'language' && e.value == null)
                'clearLanguage': true
              else
                e.key: e.value,
          },
        ),
      ),
    ),
    write(
      'game.window.bind',
      'POST',
      '/api/admin/game/bind',
      'Bind the capture to a window (hwnd or pid) or clear the binding. In '
          'external-window mode rebinding restarts the capture session.',
      const <OpParam>[
        OpParam.integer(
          'hwnd',
          description: 'Window handle from game.window.list.',
        ),
        OpParam.integer(
          'pid',
          description: 'Process id from game.window.list.',
        ),
        OpParam.boolean('clear', description: 'true = clear the binding.'),
      ],
      kit.snapshotUndo(
        read: (Map<String, String> params) async => _field(
          await kit.callRoute('GET', '/api/admin/game/status'),
          <String>['session', 'window', 'hwnd'],
        ),
        write: (Map<String, String> params, Object? old) async {
          await kit.callRoute(
            'POST',
            '/api/admin/game/bind',
            body: old == null
                ? const <String, Object?>{'clear': true}
                : <String, Object?>{'hwnd': old},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['session', 'window', 'hwnd']),
      ),
    ),
    // 不可逆：没有读路由报出当前的「外部窗口模式」开关（会话 JSON 不带），
    // 执行前抓不到旧值，撤销写不回去。
    irreversible(
      'game.window-mode.set',
      'PUT',
      '/api/admin/game/window-mode',
      'Turn external-window capture mode on or off.',
      const <OpParam>[
        OpParam.boolean('enabled', description: 'true = on.', required: true),
      ],
    ),
    read(
      'game.track.list',
      'GET',
      '/api/admin/game/tracks',
      'List engine audio tracks of the session (ptr, format, energy, selected '
          '/ excluded).',
      const <OpParam>[
        OpParam.boolean(
          'refresh',
          description: 'Refresh tracks from the helper first; default true.',
        ),
      ],
    ),
    write(
      'game.track.select',
      'POST',
      '/api/admin/game/tracks/select',
      'Select the voice track used for card audio (engine hook sessions only).',
      const <OpParam>[
        OpParam.integer(
          'ptr',
          description: 'Track ptr from game.track.list.',
          required: true,
        ),
      ],
      kit.snapshotUndo(
        read: (Map<String, String> params) async => _field(
          await kit.callRoute(
            'GET',
            '/api/admin/game/tracks',
            body: const <String, Object?>{'refresh': false},
          ),
          <String>['selected'],
        ),
        write: (Map<String, String> params, Object? old) async {
          if (old == null) {
            // 会话级选轨没有「取消选择」的入口：执行前就没选过时写不回去。
            throw const CtlFailure.conflict('执行前没有选中的音轨，无法退回「未选择」');
          }
          await kit.callRoute(
            'POST',
            '/api/admin/game/tracks/select',
            body: <String, Object?>{'ptr': old},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['selected']),
      ),
    ),
    write(
      'game.track.exclude',
      'POST',
      '/api/admin/game/tracks/exclude',
      'Exclude a track from voice capture (or include it again with '
          'excluded=false).',
      const <OpParam>[
        OpParam.integer(
          'ptr',
          description: 'Track ptr from game.track.list.',
          required: true,
        ),
        OpParam.boolean(
          'excluded',
          description: 'true = exclude (default), false = include again.',
        ),
      ],
      _keyedSnapshotUndo(
        keyOf: (CtlCall call) async => <String, Object?>{
          'ptr': call.optInt('ptr'),
        },
        read: (Map<String, Object?> key) async {
          final Object? listed = await kit.callRoute(
            'GET',
            '/api/admin/game/tracks',
            body: const <String, Object?>{'refresh': false},
          );
          final Object? rows = listed is Map ? listed['tracks'] : null;
          for (final Object? row in rows is List ? rows : const <Object?>[]) {
            if (row is Map && row['ptr'] == key['ptr']) return row['excluded'];
          }
          throw CtlFailure.notFound('会话音轨里已没有 ${key['ptr']}');
        },
        write: (Map<String, Object?> key, Object? old) async {
          await kit.callRoute(
            'POST',
            '/api/admin/game/tracks/exclude',
            body: <String, Object?>{'ptr': key['ptr'], 'excluded': old == true},
          );
        },
        newValue: (CtlCall call, Object? old, Object? result) =>
            _field(result, <String>['excluded']),
      ),
    ),
    // 只导出试听文件到临时目录、可选在 app 内播放，不改任何存储数据。
    read(
      'game.track.preview',
      'POST',
      '/api/admin/game/tracks/preview',
      'Export a short preview clip of one track (optionally for one line) and '
          'optionally play it in the app.',
      const <OpParam>[
        OpParam.integer(
          'ptr',
          description: 'Track ptr from game.track.list.',
          required: true,
        ),
        OpParam.string('lineId', description: 'Line id from game.text.'),
        OpParam.boolean('play', description: 'Play the clip in the app.'),
      ],
    ),
    read(
      'game.audio.stop',
      'POST',
      '/api/admin/game/audio/stop',
      'Stop preview audio playing in the app.',
    ),
    write(
      'game.audio-policy.set',
      'PUT',
      '/api/admin/game/audio-policy',
      'Set the voice fallback policy (whether engine PCM / loopback may be used '
          'and whether mining is blocked when voice is missing).',
      const <OpParam>[
        OpParam.string(
          'policy',
          description:
              'full = resource, engine PCM or loopback; cleanOnly = no '
              'loopback (cards without voice allowed); resourceOnly = game '
              'resource only, block mining when voice is missing.',
          required: true,
          enumValues: <String>['full', 'cleanOnly', 'resourceOnly'],
        ),
      ],
      kit.snapshotUndo(
        read: (Map<String, String> params) async => _field(
          await kit.callRoute('GET', '/api/admin/game/status'),
          <String>['session', 'audioFallbackPolicy'],
        ),
        write: (Map<String, String> params, Object? old) async {
          await kit.callRoute(
            'PUT',
            '/api/admin/game/audio-policy',
            body: <String, Object?>{'policy': old},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['policy']),
      ),
    ),
    read(
      'game.line.tracks',
      'GET',
      '/api/admin/game/lines/:id/tracks',
      'List audio tracks available for one captured line and which one it uses.',
      const <OpParam>[_lineIdParam],
    ),
    write(
      'game.line.track.set',
      'POST',
      '/api/admin/game/lines/:id/track',
      'Use another track for one line\'s voice audio.',
      const <OpParam>[
        _lineIdParam,
        OpParam.integer(
          'ptr',
          description: 'Track ptr from game.line.tracks.',
          required: true,
        ),
      ],
      kit.snapshotUndo(
        read: (Map<String, String> params) async => _field(
          await kit.callRoute(
            'GET',
            '/api/admin/game/lines/:id/tracks',
            params: params,
          ),
          <String>['chosen'],
        ),
        write: (Map<String, String> params, Object? old) async {
          if (old == null) {
            throw const CtlFailure.conflict('执行前这句没有指定音轨，无法退回');
          }
          await kit.callRoute(
            'POST',
            '/api/admin/game/lines/:id/track',
            params: params,
            body: <String, Object?>{'ptr': old},
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['chosen']),
      ),
    ),
    read(
      'game.line.preview',
      'POST',
      '/api/admin/game/lines/:id/preview',
      'Export one line\'s voice audio to a temp file and optionally play it.',
      const <OpParam>[
        _lineIdParam,
        OpParam.boolean('play', description: 'Play it in the app.'),
      ],
    ),
    // 不可逆：finish 用补录的音频替换这句原来的语音，没有路由能换回旧音频。
    irreversible(
      'game.line.recapture',
      'POST',
      '/api/admin/game/lines/:id/recapture',
      'Re-record one line\'s voice: start, then replay the voice in the game, '
          'then finish (replaces the line audio) or discard.',
      const <OpParam>[
        _lineIdParam,
        OpParam.string(
          'action',
          description: 'start | finish | discard.',
          required: true,
          enumValues: <String>['start', 'finish', 'discard'],
        ),
      ],
    ),
    write(
      'game.line.favorite',
      'POST',
      '/api/admin/game/lines/:id/favorite',
      'Toggle the favorite mark of a captured line.',
      const <OpParam>[_lineIdParam],
      kit.snapshotUndo(
        read: (Map<String, String> params) async {
          final Object? text = await kit.callRoute(
            'GET',
            '/api/admin/game/text',
            body: const <String, Object?>{'limit': 1 << 30},
          );
          final Object? lines = text is Map ? text['lines'] : null;
          for (final Object? line
              in lines is List ? lines : const <Object?>[]) {
            if (line is Map && line['id'] == params['id']) {
              return line['favorited'];
            }
          }
          throw CtlFailure.notFound('台词 ${params['id']} 已不在当前会话里');
        },
        // 走到这里说明当前状态仍是执行后的状态：再切换一次即回到执行前。
        write: (Map<String, String> params, Object? old) async {
          await kit.callRoute(
            'POST',
            '/api/admin/game/lines/:id/favorite',
            params: params,
          );
        },
        newValue: (CtlCall call, Object? result) =>
            _field(result, <String>['favorited']),
      ),
    ),
    read(
      'game.textproc.get',
      'GET',
      '/api/admin/game/textproc',
      'Read the text processing pipeline of the selected thread.',
    ),
    write(
      'game.textproc.set',
      'PUT',
      '/api/admin/game/textproc',
      'Replace the text processing pipeline of the selected thread (steps in '
          'the format returned by game.textproc.get).',
      const <OpParam>[
        // 路由要的是「步骤对象数组」；OpParamType 还没有对象数组，暂用字符串数组
        // 描述（模型给的步骤会被路由按 kind 校验并 400 回去，见回报）。
        OpParam.stringList(
          'pipeline',
          description:
              'Pipeline steps, same shape as game.textproc.get "pipeline".',
          required: true,
        ),
      ],
      kit.readBackUndo(
        readMethod: 'GET',
        readPattern: '/api/admin/game/textproc',
        writeMethod: 'PUT',
        writePattern: '/api/admin/game/textproc',
        field: 'pipeline',
      ),
    ),
    // 不可逆：清掉内存里的诊断事件，没有恢复入口。
    irreversible(
      'game.events.clear',
      'POST',
      '/api/admin/game/events/clear',
      'Clear the diagnostic event log of the capture session.',
    ),
    read(
      'game.lookup-mode.get',
      'GET',
      '/api/admin/game/lookup-mode',
      'Read the in-game (attached) lookup surface mode of the current game.',
    ),
    write(
      'game.lookup-mode.set',
      'PUT',
      '/api/admin/game/lookup-mode',
      'Set the in-game lookup surface mode for the attached game.',
      const <OpParam>[
        OpParam.string(
          'mode',
          description: 'In-game lookup surface mode.',
          required: true,
          enumValues: <String>['auto', 'nativeOnly', 'attachedOnly', 'off'],
        ),
      ],
      kit.readBackUndo(
        readMethod: 'GET',
        readPattern: '/api/admin/game/lookup-mode',
        writeMethod: 'PUT',
        writePattern: '/api/admin/game/lookup-mode',
        field: 'mode',
      ),
    ),
    // 不可逆：删除这款游戏已保存的内嵌查词校准 profile（实测几何），无法还原。
    irreversible(
      'game.lookup-profile.clear',
      'POST',
      '/api/admin/game/lookup-profile/clear',
      'Delete the saved in-game lookup calibration of the attached game.',
      const <OpParam>[
        OpParam.userGate(
          'confirm',
          description: 'User confirmed deleting the calibration.',
        ),
      ],
    ),
    read(
      'game.lookup-profile.get',
      'GET',
      '/api/admin/game/lookup-profile',
      'Read the in-game lookup state and saved calibration profile.',
    ),
    // 不可逆：实测几何写进校准 profile、覆盖同槽位旧值，没有路由能还原旧 profile；
    // 首次校准还要用户接受「左键被查词层吞掉」的风险（acceptRisk）。
    irreversible(
      'game.lookup.calibrate',
      'POST',
      '/api/admin/game/lookup-calibrate',
      'Save a measured text box geometry as the in-game lookup calibration '
          '(rect plus a cell grid or a layout object).',
      const <OpParam>[
        OpParam.string(
          'rect',
          description:
              'Text box "x,y,w,h": normalized 0-1, or pixels when px=true.',
          required: true,
        ),
        OpParam.boolean(
          'px',
          description: 'rect / grid are in screenshot pixels.',
        ),
        OpParam.boolean(
          'fromScreenshot',
          description: 'Measure against the last game.screenshot.',
        ),
        OpParam.string(
          'slot',
          description: 'Calibration slot.',
          enumValues: <String>['dialogue', 'narration'],
        ),
        OpParam.string(
          'grid',
          description: 'Cell grid "advance,lineAdvance,cellHeight,columns".',
        ),
        OpParam.object(
          'layout',
          description:
              'Full layout JSON (same as lookup-profile variants[].layout); '
              'instead of grid.',
        ),
        OpParam.number('fontSize', description: 'Font size override.'),
        OpParam.number('indent', description: 'Continuation indent in cells.'),
        OpParam.number(
          'quotedIndent',
          description: 'Continuation indent inside quotes, in cells.',
        ),
        OpParam.boolean(
          'quotedOnly',
          description: 'Only text inside quotes is dialogue.',
        ),
        OpParam.boolean(
          'explicitLineBreaks',
          description: 'The game breaks lines explicitly.',
        ),
        OpParam.userGate(
          'acceptRisk',
          description:
              'User accepted that left clicks on the lookup layer no longer '
              'reach the game.',
        ),
      ],
    ),
    // 抓游戏画面写进临时目录；故意不开放 `output`（任意路径会覆盖用户文件）。
    read(
      'game.screenshot',
      'POST',
      '/api/admin/game/screenshot',
      'Capture a screenshot of the attached game window (without Fushi '
          'overlays) to a temp PNG for calibration.',
    ),

    // ── 游戏条目管理 ───────────────────────────────────────────────────────
    write(
      'game.rename',
      'PUT',
      '/api/admin/game/games/:id/name',
      'Set a custom display name for a game, or clear it (clear=true) to use '
          'the name derived from the exe.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string('name', description: 'New display name.'),
        OpParam.boolean('clear', description: 'true = remove the custom name.'),
      ],
      _entryUndo(
        kit,
        touched: (CtlCall call) => const <String>['customName'],
        readEntry: (GalgameEntry g, List<String> keys) => <String, Object?>{
          'customName': g.customData.name,
        },
        restore: (String id, Map<String, Object?> old) => kit.callRoute(
          'PUT',
          '/api/admin/game/games/:id/name',
          params: <String, String>{'id': id},
          body: old['customName'] == null
              ? const <String, Object?>{'clear': true}
              : <String, Object?>{'name': old['customName']},
        ),
      ),
    ),
    write(
      'game.play-status.set',
      'PUT',
      '/api/admin/game/games/:id/play-status',
      'Set the play status of a game.',
      <OpParam>[
        _gameIdParam,
        OpParam.string(
          'status',
          description: 'Play status.',
          required: true,
          enumValues: <String>[
            for (final GalgamePlayStatus s in GalgamePlayStatus.values) s.name,
          ],
        ),
      ],
      _entryUndo(
        kit,
        touched: (CtlCall call) => const <String>['playStatus'],
        readEntry: (GalgameEntry g, List<String> keys) => <String, Object?>{
          'playStatus': g.playStatus.name,
        },
        restore: (String id, Map<String, Object?> old) => kit.callRoute(
          'PUT',
          '/api/admin/game/games/:id/play-status',
          params: <String, String>{'id': id},
          body: <String, Object?>{'status': old['playStatus']},
        ),
      ),
    ),
    // 不可逆：导入封面会先删掉游戏封面目录里的旧封面文件，没有路由能找回旧图。
    irreversible(
      'game.cover.set',
      'POST',
      '/api/admin/game/games/:id/cover',
      'Replace a game\'s cover with a local image file, or auto-detect one '
          '(auto=true: cover image in the game folder, else the exe icon). '
          'The previous cover file is deleted.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string('file', description: 'Absolute path of an image file.'),
        OpParam.boolean('auto', description: 'true = auto-detect a cover.'),
      ],
    ),
    write(
      'game.edit',
      'PUT',
      '/api/admin/game/games/:id/details',
      'Edit game details: exe path, working directory, launch arguments, '
          'summary, tags, developer, rating, review, release date, NSFW flag. '
          'Only the given fields change; list fields to empty in clear.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string('exePath', description: 'Absolute exe path.'),
        OpParam.string('workdir', description: 'Working directory.'),
        OpParam.string('launchArgs', description: 'Launch arguments.'),
        OpParam.string('summary', description: 'Summary text.'),
        OpParam.string('tags', description: 'Tags, comma separated.'),
        OpParam.string('developer', description: 'Developer.'),
        OpParam.number('rating', description: 'My rating 0-10.'),
        OpParam.string('review', description: 'My review.'),
        OpParam.string('releaseDate', description: 'Release date YYYY-MM-DD.'),
        OpParam.boolean('nsfw', description: 'Adult content flag.'),
        OpParam.stringList(
          'clear',
          description:
              'Fields to empty: launchArgs, summary, tags, developer, nsfw, '
              'rating, review, releaseDate.',
        ),
      ],
      _entryUndo(
        kit,
        touched: (CtlCall call) {
          final List<String> clear = call.stringList('clear');
          return <String>[
            for (final String f in _editFields)
              if (call.body[f] != null || clear.contains(f)) f,
          ];
        },
        readEntry: _detailFields,
        restore: (String id, Map<String, Object?> old) => kit.callRoute(
          'PUT',
          '/api/admin/game/games/:id/details',
          params: <String, String>{'id': id},
          body: _detailRestoreBody(old),
        ),
      ),
    ),
    // 不可逆：从库移除条目（磁盘上的游戏文件不动）；没有「按原 id 加回」的路由，
    // 刮削资料与封面关联随条目一起丢失，选了 deleteStatistics 时统计也删除。
    irreversible(
      'game.remove',
      'DELETE',
      '/api/admin/game/games/:id',
      'Remove a game from the library (game files on disk are kept; metadata '
          'is lost). deleteStatistics=true also deletes its play statistics.',
      const <OpParam>[
        _gameIdParam,
        OpParam.boolean(
          'deleteStatistics',
          description: 'Also delete the game\'s play sessions / statistics.',
        ),
        OpParam.userGate(
          'confirm',
          description: 'User confirmed removing the game.',
        ),
      ],
    ),
    read(
      'game.session.list',
      'GET',
      '/api/admin/game/games/:id/sessions',
      'List play sessions of a game (start, end, duration).',
      const <OpParam>[
        _gameIdParam,
        OpParam.integer('limit', description: 'Page size; default 50.'),
        OpParam.integer('offset', description: 'Offset; default 0.'),
      ],
    ),
    // 不可逆：真删一条游玩会话（改变统计时长），没有恢复路由。
    irreversible(
      'game.session.delete',
      'DELETE',
      '/api/admin/game/games/:id/sessions/:sessionId',
      'Delete one play session of a game (changes play-time statistics).',
      const <OpParam>[
        _gameIdParam,
        OpParam.string(
          'sessionId',
          description: 'Session id from game.session.list.',
          required: true,
          inPath: true,
        ),
        OpParam.userGate(
          'confirm',
          description: 'User confirmed deleting the session.',
        ),
      ],
    ),
    read(
      'game.scrape.search',
      'GET',
      '/api/admin/game/games/:id/scrape',
      'Search metadata sources (VNDB etc.) for a game; returns candidate ids '
          'for game.scrape.apply.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string(
          'q',
          description: 'Search text; default the game title.',
        ),
        OpParam.string(
          'source',
          description: 'Only this metadata source; default all.',
          enumValues: <String>['bgm', 'vndb', 'dlsite'],
        ),
      ],
    ),
    // 不可逆：覆盖该源的资料快照、主显示源与发行日（可能连带封面），没有路由能
    // 退回旧快照。
    irreversible(
      'game.scrape.apply',
      'POST',
      '/api/admin/game/games/:id/scrape',
      'Apply a metadata candidate to a game (overwrites that source\'s '
          'snapshot, the primary source and the release date).',
      const <OpParam>[
        _gameIdParam,
        OpParam.string(
          'candidate',
          description:
              'Candidate id "<source>:<externalId>" from '
              'game.scrape.search.',
          required: true,
        ),
      ],
    ),
    read(
      'game.source.list',
      'GET',
      '/api/admin/game/games/:id/sources',
      'List metadata sources saved for a game.',
      const <OpParam>[_gameIdParam],
    ),
    // 不可逆：删掉该源的资料快照，要恢复只能重新联网刮削。
    irreversible(
      'game.source.remove',
      'DELETE',
      '/api/admin/game/games/:id/sources/:source',
      'Delete one metadata source snapshot of a game.',
      const <OpParam>[
        _gameIdParam,
        OpParam.string(
          'source',
          description: 'Source key from game.source.list.',
          required: true,
          inPath: true,
        ),
      ],
    ),
  ];
}

const OpParam _gameIdParam = OpParam.string(
  'id',
  description: 'Game id from game.list.',
  required: true,
  inPath: true,
);

const OpParam _lineIdParam = OpParam.string(
  'id',
  description: 'Line id from game.text.',
  required: true,
  inPath: true,
);

/// 平台判据（与路由的 `_requireHook` 同一条：Galgame Hook 只做 Windows）。测试
/// 在非 Windows 的 CI 上跑撤销往返时替换它。
@visibleForTesting
bool Function() gameOpsPlatformSupported = () => Platform.isWindows;

OpAvailability _windowsOnly() => gameOpsPlatformSupported()
    ? const OpAvailability.available()
    : const OpAvailability.unavailable(
        'platform_unsupported',
        'Galgame Hook 只支持 Windows',
      );

/// 沿 [path] 取嵌套 Map 里的一个值；任一层不是 Map 时为 null。
Object? _field(Object? value, List<String> path) {
  Object? current = value;
  for (final String key in path) {
    if (current is! Map) return null;
    current = current[key];
  }
  return current;
}

// ── 条目快照 ──────────────────────────────────────────────────────────────

const List<String> _editFields = <String>[
  'exePath',
  'workdir',
  'launchArgs',
  'summary',
  'tags',
  'developer',
  'review',
  'rating',
  'releaseDate',
  'nsfw',
];

/// 详情字段，与路由 `_gameJson` 同口径（customData 覆盖层上的那几项）。
Map<String, Object?> _detailFields(GalgameEntry g, List<String> keys) {
  final Map<String, Object?> all = <String, Object?>{
    'exePath': g.exePath,
    'workdir': g.workdir,
    'launchArgs': g.launchArgs,
    'summary': g.customData.summary,
    'tags': g.customData.tags,
    'developer': g.customData.developer,
    'review': g.customData.userReview,
    'rating': g.customData.userRating,
    'releaseDate': g.releaseDate,
    'nsfw': g.customData.nsfw,
  };
  return <String, Object?>{for (final String k in keys) k: all[k]};
}

/// 启动期配置，与路由出参同一套归一化（未设置的空串按解析层回落值报）。
Map<String, Object?> _configFields(GalgameEntry g, List<String> keys) {
  final Map<String, Object?> all = <String, Object?>{
    'locale': galJapaneseLocaleModeToKey(
      galJapaneseLocaleModeFromKey(g.japaneseLocaleMode),
    ),
    'upscaling': magpieUpscalingModeToKey(
      magpieUpscalingModeFromKey(g.upscalingMode),
    ),
    'language': g.language,
  };
  return <String, Object?>{for (final String k in keys) k: all[k]};
}

/// 把详情快照写回：空值进 `clear`，其余按路由入参格式给。
Map<String, Object?> _detailRestoreBody(Map<String, Object?> old) {
  final List<String> clear = <String>[];
  final Map<String, Object?> body = <String, Object?>{};
  for (final MapEntry<String, Object?> e in old.entries) {
    final Object? v = e.value;
    final bool empty =
        v == null ||
        (e.key == 'launchArgs' && v == '') ||
        (e.key == 'tags' && v is List && v.isEmpty);
    if (empty) {
      clear.add(e.key);
    } else if (v is List) {
      body[e.key] = v.join(',');
    } else if (v is num) {
      body[e.key] = '$v';
    } else {
      body[e.key] = v;
    }
  }
  return <String, Object?>{...body, if (clear.isNotEmpty) 'clear': clear};
}

/// 写路由出参（`_gameJson` / config 出参）里对应 [keys] 的值；缺省的可空项为 null，
/// 标签缺省为空表（`_gameJson` 只在非空时带 tags）。
Map<String, Object?> _resultFields(Object? result, List<String> keys) =>
    <String, Object?>{
      for (final String k in keys)
        k: switch (_field(result, <String>[k])) {
          null when k == 'tags' => const <String>[],
          final Object? v => v,
        },
    };

/// 游戏条目当前值：直接读游戏仓储（与路由宿主同一个 `AppModel.galgameRepo`）。
Future<GalgameEntry> _entryOf(OpDescribeKit kit, String rawId) async {
  final String id = rawId.startsWith('game:') ? rawId.substring(5) : rawId;
  final GalgameRepository repo = kit.context.appModel.galgameRepo;
  if (!repo.isLoaded) await repo.load();
  final GalgameEntry? entry = repo.byId(id);
  if (entry == null) throw CtlFailure.notFound('游戏库里没有 game:$id');
  return entry;
}

/// 条目字段的快照撤销：执行前从仓储读 [touched] 那几项，撤销前再读一次与执行
/// 结果比对（被手动改过 → superseded），再经 [restore]（同一组写路由）写回。
OpUndo _entryUndo(
  OpDescribeKit kit, {
  required List<String> Function(CtlCall call) touched,
  required Map<String, Object?> Function(GalgameEntry g, List<String> keys)
  readEntry,
  required Future<Object?> Function(String id, Map<String, Object?> old)
  restore,
}) => _keyedSnapshotUndo(
  keyOf: (CtlCall call) async {
    final GalgameEntry entry = await _entryOf(kit, call.params['id']!);
    return <String, Object?>{'id': entry.id, 'keys': touched(call)};
  },
  read: (Map<String, Object?> key) async =>
      readEntry(await _entryOf(kit, key['id']! as String), _keys(key)),
  write: (Map<String, Object?> key, Object? old) async {
    await restore(key['id']! as String, Map<String, Object?>.from(old! as Map));
  },
  newValue: (CtlCall call, Object? old, Object? result) =>
      _resultFields(result, _keys(<String, Object?>{'keys': touched(call)})),
);

List<String> _keys(Map<String, Object?> key) => <String>[
  for (final Object? k in (key['keys'] as List? ?? const <Object?>[])) '$k',
];

// ── 通用：带键的快照撤销 ──────────────────────────────────────────────────

/// [OpDescribeKit.snapshotUndo] 的变体：快照键由 [keyOf] 从整个调用（含 body、
/// 可异步解析，如把 `game:` 前缀 id 归一）算出并持久化进载荷，[newValue] 还能看到
/// 旧值。撤销前读当前值，不等于执行结果就报 superseded、不覆盖手动修改。
OpUndo _keyedSnapshotUndo({
  required Future<Map<String, Object?>> Function(CtlCall call) keyOf,
  required Future<Object?> Function(Map<String, Object?> key) read,
  required Future<void> Function(Map<String, Object?> key, Object? old) write,
  required Object? Function(CtlCall call, Object? old, Object? result) newValue,
}) => OpUndo(
  capture: (CtlCall call) async {
    final Map<String, Object?> key = await keyOf(call);
    return <String, Object?>{'key': key, 'old': await read(key)};
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? after = newValue(call, before['old'], result);
    return OpUndoRecord(
      payload: <String, Object?>{...before, 'new': after},
      before: _display(before['old']),
      after: _display(after),
    );
  },
  revert: (Map<String, Object?> payload) async {
    final Map<String, Object?> key = Map<String, Object?>.from(
      payload['key'] as Map? ?? const <String, Object?>{},
    );
    try {
      if (!OpDescribeKit.sameJson(await read(key), payload['new'])) {
        return const OpUndoOutcome.superseded();
      }
      await write(key, payload['old']);
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return failure.status == 404
          ? OpUndoOutcome.superseded(failure.message)
          : OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

String? _display(Object? value) {
  if (value == null) return null;
  final String text = value is String ? value : jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

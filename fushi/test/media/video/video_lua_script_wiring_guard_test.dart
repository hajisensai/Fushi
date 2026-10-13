import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-2032 接线守卫：Lua 脚本"导入了但用不了"的四条根因各自有一个接线点，
/// 任何一处被回退都会退化成静默失效，而这些接线在 widget/单元层没有可探的
/// 渲染输入（真播放器 + 真 mpv 日志），只能靠源码守卫咬住。
///
/// 注释先剥掉再匹配：注释里同一串字面量会先被 indexOf 命中，让顺序断言恒真。
void main() {
  const String controllerPath =
      'lib/src/media/video/video_player_controller.dart';
  const String schemaPath = 'lib/src/settings/settings_schema_video.dart';
  const String pagePath = 'lib/src/pages/implementations/video_fushi_page.dart';

  // 等长掩码（helpers/source_guard.dart），下标与原文一致，顺序断言可直接比较。
  String code(String path) => maskComments(File(path).readAsStringSync());

  group('VideoPlayerController', () {
    late String src;
    setUpAll(() => src = code(controllerPath));

    test('Player 建好即订阅 mpv 日志做脚本报错归因', () {
      expect(
        src,
        contains(
          '_luaLogSub = player.stream.log.listen(_onMpvLogForLuaScripts);',
        ),
        reason: '没有日志订阅，脚本报错就回到"零诊断"',
      );
    });

    test('Player 置 null 的两处（dispose / _releaseMediaHandles）都走同一收口', () {
      // 去重集 / 状态表 / 日志订阅三者作用域都是单个 Player，漏一处就是新 Player
      // 一条 load-script 都不发、或旧 Player 的报错挂到新 Player 上。
      final int disposeIdx = src.indexOf('void dispose() {');
      final int releaseIdx = src.indexOf('Future<void> _releaseMediaHandles()');
      expect(disposeIdx, greaterThan(0));
      expect(releaseIdx, greaterThan(disposeIdx));
      final String disposeBody = src.substring(disposeIdx, releaseIdx);
      final String releaseBody = src.substring(
        releaseIdx,
        src.indexOf('}', src.indexOf('await player.dispose();', releaseIdx)),
      );
      expect(disposeBody, contains('_resetLuaScriptState();'));
      expect(releaseBody, contains('_resetLuaScriptState();'));
      // 不允许绕开收口直接 clear（那样状态表/订阅就漏了）。
      expect(
        RegExp(r'_loadedLuaScripts\.clear\(\);').allMatches(src).length,
        1,
        reason: '_loadedLuaScripts.clear() 只能出现在 _resetLuaScriptState 里',
      );
    });

    test('applyLuaScripts：先开文字 OSD 层再 load-script', () {
      final int fn = src.indexOf('Future<void> applyLuaScripts(');
      expect(fn, greaterThan(0));
      final String body = src.substring(fn, src.indexOf('\n  }\n', fn));
      final int osd = body.indexOf(
        '_setMpvProperties(buildLuaOsdProperties())',
      );
      final int load = body.indexOf('applyLuaScriptsToPlayer(player, fresh)');
      expect(osd, greaterThan(0), reason: '不抬 osd-level，mp.osd_message 永不可见');
      expect(
        load,
        greaterThan(osd),
        reason: 'OSD 属性必须先于 load-script，脚本初始化时的提示才画得出来',
      );
      expect(
        body,
        contains('luaScriptStates.value ='),
        reason: '下发即登记状态表，设置页才知道"本次播放已装载"',
      );
    });

    test('load()：先探 Lua 能力再装脚本，且都在 open 之前', () {
      final int probe = src.indexOf('await _probeLuaCapability();');
      final int apply = src.indexOf('await applyLuaScripts(luaScriptPaths);');
      final int open = src.indexOf('await player.open(', apply);
      expect(probe, greaterThan(0));
      expect(apply, greaterThan(probe));
      expect(
        open,
        greaterThan(apply),
        reason: 'load-script 晚于 open 会错过首个文件的 start-file/file-loaded',
      );
    });

    // #2014：字幕由 overlay 画、libmpv sid 恒为 no，sub-text 类脚本（字幕结束暂停）
    // 永远收不到字幕。镜像轨的接线点任何一处断掉都是静默失效。
    group('Lua 字幕镜像', () {
      String body(String signature) {
        final int fn = src.indexOf(signature);
        expect(fn, greaterThan(0), reason: '找不到 $signature');
        return src.substring(fn, src.indexOf('\n  }\n', fn));
      }

      test('换主字幕（setCues）即重挂镜像', () {
        expect(
          body('void setCues(List<AudioCue> cues) {'),
          contains('_scheduleLuaSubtitleMirrorSync();'),
        );
      });

      test('中途装脚本立刻镜像当前字幕', () {
        final String fn = body('Future<void> applyLuaScripts(');
        expect(
          fn.indexOf('_scheduleLuaSubtitleMirrorSync();'),
          greaterThan(fn.indexOf('applyLuaScriptsToPlayer(player, fresh)')),
        );
      });

      test('关字幕 no() 会把镜像一起取消选中，之后要重挂', () {
        expect(
          body('Future<void> selectSubtitleTrack(SubtitleTrack track)'),
          contains("if (track.id == 'no') _scheduleLuaSubtitleMirrorSync();"),
        );
      });

      test('load()：镜像在 open 后的 setSubtitleTrack(no()) 之后才放行', () {
        final int noTrack = src.indexOf(
          'await player.setSubtitleTrack(SubtitleTrack.no());',
          src.indexOf('await player.open('),
        );
        final int ready = src.indexOf('_luaSubtitleMirrorFileReady = true;');
        expect(noTrack, greaterThan(0));
        expect(ready, greaterThan(noTrack), reason: '早于 no() 选中的镜像会被它立刻取消选中');
      });

      test('选轨 / 数轨不把镜像轨当成用户的字幕源', () {
        expect(
          RegExp(
            r"\.where\(\(SubtitleTrack t\) => t\.id != 'auto' && t\.id != 'no'\)",
          ).hasMatch(src),
          isFalse,
          reason: '裸 auto/no 过滤会把镜像轨数进真实轨，改用 _isRealSubtitleTrack',
        );
        expect(
          body('static bool _isRealSubtitleTrack(SubtitleTrack t) =>'),
          contains('isLuaSubtitleMirrorTrack(t)'),
        );
      });

      test('调轴烘进镜像 SRT，并随调轴重挂（mpv 的 sub-end 不含 sub-delay）', () {
        expect(
          body('Future<void> _syncLuaSubtitleMirror() async {'),
          contains('buildLuaSubtitleMirrorSrt(_cues, delayMs: _delayMs)'),
        );
        expect(
          body('void setDelayMs(int delayMs) {'),
          contains('_scheduleLuaSubtitleMirrorSync();'),
        );
        expect(
          src,
          contains(
            'int get _subtitleDelayMpvMs => _graphicSubtitleActive ? _delayMs : 0;',
          ),
          reason: '镜像轨若再叠 sub-delay，脚本看到的句尾会偏两倍',
        );
      });
    });
  });

  group('settings schema', () {
    late String src;
    setUpAll(() => src = code(schemaPath));

    test('导入按钮走与开关同一条写穿并置 true（导入即启用）', () {
      final int importIdx = src.indexOf(
        "id: 'video.player.mpv_lua_scripts_import'",
      );
      final int dirIdx = src.indexOf("id: 'video.player.mpv_lua_scripts_dir'");
      expect(importIdx, greaterThan(0));
      expect(dirIdx, greaterThan(importIdx));
      final String between = src.substring(importIdx, dirIdx);
      expect(
        between,
        contains('_setVideoLuaScriptsEnabled(settingsContext, true)'),
        reason: '导入后不启用 = 用户播视频什么都不发生（BUG-2032 根因②）',
      );
    });

    test('开关行 onChanged 也走同一条写穿（不允许两份实现分叉）', () {
      final int switchIdx = src.indexOf("id: 'video.player.mpv_lua_scripts'");
      final int importIdx = src.indexOf(
        "id: 'video.player.mpv_lua_scripts_import'",
      );
      final String between = src.substring(switchIdx, importIdx);
      expect(between, contains('onChanged: _setVideoLuaScriptsEnabled'));
      expect(
        between,
        contains('MpvLuaCapability.unavailable'),
        reason: '能力不可用要在副标题如实说明',
      );
    });

    test('脚本状态列表项挂在 mpv 高级分区', () {
      expect(src, contains("id: 'video.player.mpv_lua_scripts_list'"));
      expect(src, contains('builder: buildVideoLuaScriptList'));
    });
  });

  group('VideoFushiPage', () {
    late String src;
    setUpAll(() => src = code(pagePath));

    test('把 controller 的脚本状态表交给设置面板 host', () {
      expect(src, contains('luaScriptStates: _controller?.luaScriptStates'));
    });

    test('load 完成后把探到的 Lua 能力落 pref', () {
      expect(
        src,
        contains('appModel.setVideoMpvLuaCapability(controller.luaCapability)'),
      );
    });
  });
}

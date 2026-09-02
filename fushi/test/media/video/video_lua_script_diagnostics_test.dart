import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart';

/// BUG-2032：Lua 脚本能力判定 / 日志归因 / OSD 属性三组纯函数。
void main() {
  group('parseMpvLuaCapability', () {
    test('Windows 随包（zhongfly）构建串 → available', () {
      // 真机探针原文节选（fushi/build/windows/x64/runner/Release/libmpv-2.dll）。
      const String cfg = '-Dprefix=/x -Dlibmpv=true -Dlua=enabled '
          '-Djavascript=enabled -Dvulkan=enabled';
      expect(parseMpvLuaCapability(cfg), MpvLuaCapability.available);
    });

    test('Android 随包（media-kit full jar）构建串 → unavailable', () {
      // libmpv-android-full-arm64-v8a-ffmpeg6.1.6.jar 里 libmpv.so 的原文节选。
      const String cfg = '-Dbuildtype=release -Dlua=disabled -Dgpl=false';
      expect(parseMpvLuaCapability(cfg), MpvLuaCapability.unavailable);
    });

    test('显式指定实现（luajit / lua52 / lua）都算 available', () {
      for (final String v in <String>['luajit', 'lua52', 'lua51', 'lua']) {
        expect(
          parseMpvLuaCapability('-Dlua=$v'),
          MpvLuaCapability.available,
          reason: v,
        );
      }
    });

    test('auto 看不出结果、空串/无 -Dlua= 都归 unknown（不能拿不知道当不可用）', () {
      expect(parseMpvLuaCapability('-Dlua=auto'), MpvLuaCapability.unknown);
      expect(parseMpvLuaCapability(''), MpvLuaCapability.unknown);
      expect(parseMpvLuaCapability('--enable-lua'), MpvLuaCapability.unknown);
    });

    test('fromName 还原持久化值，脏值回 unknown', () {
      for (final MpvLuaCapability v in MpvLuaCapability.values) {
        expect(MpvLuaCapability.fromName(v.name), v);
      }
      expect(MpvLuaCapability.fromName('bogus'), MpvLuaCapability.unknown);
      expect(MpvLuaCapability.fromName(null), MpvLuaCapability.unknown);
    });
  });

  group('luaScriptNameForPath（复刻 mpv script_name_from_filename）', () {
    test('去扩展名、非字母数字改下划线、去前导 @', () {
      expect(
        luaScriptNameForPath(r'C:\a b\auto-profile.v2.lua'),
        'auto_profile_v2',
      );
      expect(luaScriptNameForPath('/home/u/mpv_scripts/osc.lua'), 'osc');
      expect(luaScriptNameForPath('/x/@thumbfast.lua'), 'thumbfast');
      expect(luaScriptNameForPath('/x/日本語.lua'), '___');
    });
  });

  group('matchLuaLogToScripts', () {
    const String a = r'C:\u\Documents\Fushi\data\mpv_scripts\a-one.lua';
    const String b = r'C:\u\Documents\Fushi\data\mpv_scripts\b_two.lua';
    const List<String> scripts = <String>[a, b];

    test('cplayer 装载失败：按完整路径归到那一条脚本', () {
      final LuaScriptLogHit? hit = matchLuaLogToScripts(
        prefix: 'cplayer',
        level: 'error',
        text: 'Could not load lua script $b\n',
        scriptPaths: scripts,
      );
      expect(hit, isNotNull);
      expect(hit!.paths, <String>[b]);
      expect(hit.message, 'Could not load lua script $b');
    });

    test('脚本前缀 fatal（Lua error）：按客户端名归因', () {
      final LuaScriptLogHit? hit = matchLuaLogToScripts(
        prefix: 'a_one',
        level: 'fatal',
        text: 'Lua error: a-one.lua:3: attempt to call a nil value',
        scriptPaths: scripts,
      );
      expect(hit?.paths, <String>[a]);
    });

    test('脚本自己 mp.msg.error 也归因（error 级、脚本前缀）', () {
      final LuaScriptLogHit? hit = matchLuaLogToScripts(
        prefix: 'b_two',
        level: 'error',
        text: 'config file missing',
        scriptPaths: scripts,
      );
      expect(hit?.paths, <String>[b]);
    });

    test('info/verbose 级、无关前缀、无关 cplayer 报错、空正文 → null', () {
      expect(
        matchLuaLogToScripts(
          prefix: 'a_one',
          level: 'info',
          text: 'hello',
          scriptPaths: scripts,
        ),
        isNull,
      );
      expect(
        matchLuaLogToScripts(
          prefix: 'ytdl_hook',
          level: 'error',
          text: 'youtube-dl failed',
          scriptPaths: scripts,
        ),
        isNull,
      );
      expect(
        matchLuaLogToScripts(
          prefix: 'cplayer',
          level: 'error',
          text: 'Failed to open other.mkv',
          scriptPaths: scripts,
        ),
        isNull,
      );
      expect(
        matchLuaLogToScripts(
          prefix: 'a_one',
          level: 'error',
          text: '  \n',
          scriptPaths: scripts,
        ),
        isNull,
      );
    });

    test('同名多脚本一起命中（宁多标不漏标）', () {
      const List<String> dup = <String>['/x/osc.lua', '/y/osc.lua'];
      final LuaScriptLogHit? hit = matchLuaLogToScripts(
        prefix: 'osc',
        level: 'fatal',
        text: 'Lua error: boom',
        scriptPaths: dup,
      );
      expect(hit?.paths, dup);
    });
  });

  group('buildLuaOsdProperties', () {
    test('打开文字 OSD 层且 seek 不弹原生进度条', () {
      final Map<String, String> props = buildLuaOsdProperties();
      // osd-level=0 是 media_kit 写死的默认（real.dart:2421），mpv 在
      // set_osd_msg_va 里直接丢弃 level>osd-level 的消息：不抬到 1，
      // mp.osd_message 永远不可见。
      expect(props['osd-level'], '1');
      // Hibiki 有自己的进度条；mpv 默认 osd-on-seek=bar 会在每次 seek 叠一条。
      expect(props['osd-on-seek'], 'no');
      expect(props.length, 2);
    });
  });
}

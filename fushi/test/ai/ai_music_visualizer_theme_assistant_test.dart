/// AI 歌词动画主题（AiFeature.musicVisualizerTheme）的本地校验（移植 folia themeSanitizer）、
/// 提示词与一次真实的 complete 往返（假 HTTP）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_music_visualizer_theme_assistant.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

Map<String, Object?> _variant({
  String bg = '#1b2440',
  String text = '#eef2ff',
  String accent = '#f0a0c0',
  String secondary = '#c0c8e0',
  List<Object?> words = const <Object?>[],
}) => <String, Object?>{
  'name': '夜',
  'description': '耳机里的夜晚',
  'backgroundColor': bg,
  'primaryColor': text,
  'accentColor': accent,
  'secondaryColor': secondary,
  'wordColors': words,
};

Map<String, Object?> _dual({
  Map<String, Object?>? light,
  Map<String, Object?>? dark,
  Object? intensity = 'calm',
  Object? font = 'serif',
}) => <String, Object?>{
  'animationIntensity': intensity,
  'fontStyle': font,
  'light':
      light ??
      _variant(
        bg: '#fdf6e3',
        text: '#2a2233',
        accent: '#b0306a',
        secondary: '#5a5266',
      ),
  'dark': dark ?? _variant(),
};

const String _lyrics = '夜空に光る星\nThe train is gone, hidden cities\n君の涙';

void main() {
  group('颜色', () {
    test('只认 #rgb / #rrggbb，结果不透明', () {
      expect(parseAiVisualizerColor('#abc'), const Color(0xFFAABBCC));
      expect(parseAiVisualizerColor(' #A1B2C3 '), const Color(0xFFA1B2C3));
      expect(parseAiVisualizerColor('#80a1b2c3'), isNull);
      expect(parseAiVisualizerColor('red'), isNull);
      expect(parseAiVisualizerColor('rgb(1,2,3)'), isNull);
      expect(parseAiVisualizerColor(0xFF112233), isNull);
      expect(aiVisualizerHex(const Color(0xFF0A0B0C)), '#0a0b0c');
    });
  });

  group('sanitize', () {
    test('正常回复：两套配色、强度、字体照收', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(),
        source: _lyrics,
      )!;
      expect(t.dark.background, const Color(0xFF1B2440));
      expect(t.dark.text, const Color(0xFFEEF2FF));
      expect(t.light.background, const Color(0xFFFDF6E3));
      expect(t.intensity, LyricVisualizerIntensity.calm);
      expect(t.fontStyle, AiVisualizerFontStyle.serif);
      expect(t.dark.name, '夜');
    });

    test('认不出的颜色回落 folia 兜底，枚举认不出取默认', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(
          dark: _variant(text: 'white', accent: '#zzz'),
          intensity: 'wild',
          font: 'comic',
        ),
        source: _lyrics,
      )!;
      expect(t.dark.text, kAiVisualizerFallbackDark.text);
      expect(t.dark.accent, kAiVisualizerFallbackDark.accent);
      expect(t.intensity, LyricVisualizerIntensity.normal);
      expect(t.fontStyle, AiVisualizerFontStyle.sans);
    });

    test('背景亮度与模式不符换成兜底背景；对比度不够的正文 / 次要 / 强调被换掉', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(
          // 暗色模式给了白底。
          dark: _variant(bg: '#ffffff'),
          // 亮色模式：正文 / 次要 / 强调都几乎与背景同色。
          light: _variant(
            bg: '#fafafa',
            text: '#f0f0f0',
            secondary: '#eeeeee',
            accent: '#f5f5f5',
          ),
        ),
        source: _lyrics,
      )!;
      expect(t.dark.background, kAiVisualizerFallbackDark.background);
      for (final AiVisualizerThemeVariant v in <AiVisualizerThemeVariant>[
        t.light,
        t.dark,
      ]) {
        expect(
          aiVisualizerContrast(v.text, v.background),
          greaterThanOrEqualTo(kAiVisualizerMinTextContrast),
        );
        expect(
          aiVisualizerContrast(v.secondary, v.background),
          greaterThanOrEqualTo(kAiVisualizerMinSecondaryContrast),
        );
        expect(
          aiVisualizerContrast(v.accent, v.background),
          greaterThanOrEqualTo(kAiVisualizerMinAccentContrast),
        );
      }
    });

    test('关键词必须在歌词里出现；拉丁词去外围标点、拒短语、去重、不分大小写', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(
          dark: _variant(
            words: <Object?>[
              <String, Object?>{'word': '星', 'color': '#ffd700'},
              <String, Object?>{'word': '「涙」', 'color': '#88aaff'},
              <String, Object?>{'word': 'Train', 'color': '#ff0000'},
              <String, Object?>{'word': 'train', 'color': '#00ff00'},
              <String, Object?>{'word': 'gone,', 'color': 'bogus'},
              <String, Object?>{'word': 'hidden cities', 'color': '#123456'},
              <String, Object?>{'word': "train's", 'color': '#123456'},
              <String, Object?>{'word': '太陽', 'color': '#123456'},
              <String, Object?>{'word': 'sun', 'color': '#123456'},
              <String, Object?>{'word': '', 'color': '#123456'},
              <String, Object?>{'color': '#123456'},
              'nope',
            ],
          ),
        ),
        source: _lyrics,
      )!;
      expect(t.dark.wordColors.keys.toList(), <String>[
        '星',
        '涙',
        'Train',
        'gone',
      ]);
      // 词色认不出 → 本套强调色（folia）。
      expect(t.dark.wordColors['gone'], t.dark.accent);
      // 落进框架后按词着色能命中。
      final LyricVisualizerTheme vt = t.toVisualizerTheme(Brightness.dark);
      expect(vt.colorRangesFor('The train is gone').map((r) => r.start), <int>[
        4,
        13,
      ]);
    });

    test('关键词最多保留上限个', () {
      final String source = List<String>.generate(
        40,
        (int i) => 'w$i',
      ).join(' ');
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(
          dark: _variant(
            words: <Object?>[
              for (int i = 0; i < 40; i++)
                <String, Object?>{'word': 'w$i', 'color': '#ffffff'},
            ],
          ),
        ),
        source: source,
      )!;
      expect(t.dark.wordColors.length, kAiVisualizerMaxWordColors);
    });

    test('没分明暗的单套回复两种模式共用；一个颜色都没有 = 失败', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _variant(bg: '#101020'),
        source: _lyrics,
      )!;
      expect(t.dark.background, const Color(0xFF101020));
      // 亮色模式拿到暗底 → 换兜底亮底。
      expect(t.light.background, kAiVisualizerFallbackLight.background);
      expect(
        sanitizeAiMusicVisualizerTheme(<String, Object?>{
          'light': <String, Object?>{'name': 'x'},
        }, source: _lyrics),
        isNull,
      );
      expect(parseAiMusicVisualizerTheme('not json', source: _lyrics), isNull);
    });

    test('名字 / 描述截短；JSON 往返不变', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(
          dark: <String, Object?>{
            ..._variant(
              words: <Object?>[
                <String, Object?>{'word': '星', 'color': '#ffd700'},
              ],
            ),
            'name': 'x' * 100,
            'description': 'y' * 300,
          },
        ),
        source: _lyrics,
      )!;
      expect(t.dark.name.length, kAiVisualizerMaxNameChars);
      expect(t.dark.description.length, kAiVisualizerMaxDescriptionChars);
      final AiMusicVisualizerTheme back = AiMusicVisualizerTheme.fromJson(
        jsonDecode(jsonEncode(t.toJson())),
      )!;
      expect(back, t);
    });

    test('转成框架主题：folia primary→text、accent→primary/accent、字体族提示', () {
      final AiMusicVisualizerTheme t = sanitizeAiMusicVisualizerTheme(
        _dual(font: 'mono'),
        source: _lyrics,
      )!;
      final LyricVisualizerTheme dark = t.toVisualizerTheme(Brightness.dark);
      expect(dark.palette!.text, t.dark.text);
      expect(dark.palette!.primary, t.dark.accent);
      expect(dark.palette!.accent, t.dark.accent);
      expect(dark.palette!.background, t.dark.background);
      expect(dark.intensity, LyricVisualizerIntensity.calm);
      expect(dark.fontFamily, 'monospace');
      expect(
        t.toVisualizerTheme(Brightness.light).palette!.background,
        t.light.background,
      );
    });
  });

  group('提示词', () {
    test('歌词片段跳过和声行与空行并截长', () {
      final LyricTimeline tl = LyricTimeline(
        format: 'lrc',
        lines: <LyricLine>[
          const LyricLine(
            startMs: 0,
            endMs: 1,
            syllables: <LyricSyllable>[
              LyricSyllable(text: 'main', startMs: 0, endMs: 1),
            ],
          ),
          const LyricLine(
            startMs: 1,
            endMs: 2,
            role: LyricRole.background,
            syllables: <LyricSyllable>[
              LyricSyllable(text: 'bg', startMs: 1, endMs: 2),
            ],
          ),
          const LyricLine(
            startMs: 2,
            endMs: 3,
            syllables: <LyricSyllable>[
              LyricSyllable(text: '  ', startMs: 2, endMs: 3),
            ],
          ),
          for (int i = 0; i < 200; i++)
            LyricLine(
              startMs: 10 + i,
              endMs: 11 + i,
              syllables: <LyricSyllable>[
                LyricSyllable(text: 'line $i ' * 3, startMs: 0, endMs: 1),
              ],
            ),
        ],
      );
      final String s = aiVisualizerLyricsSnippet(tl);
      expect(s.startsWith('main\nline 0'), isTrue);
      expect(s.contains('bg'), isFalse);
      expect(s.length, lessThanOrEqualTo(kAiVisualizerSourceMaxChars));
      expect(aiVisualizerLyricsSnippet(null), '');
    });

    test('没有歌词按纯音乐：原文是歌名，关键词出处也是歌名', () {
      final String p = buildAiMusicVisualizerThemeUserPrompt(
        title: 'Snow Halation',
        artist: 'μ’s',
        lyricsSnippet: '',
        uiLanguage: 'zh-CN',
      );
      expect(p, contains('Pure instrumental: yes'));
      expect(p, contains('Write names in: zh-CN'));
      expect(p.trimRight().endsWith('Snow Halation'), isTrue);
      expect(
        aiVisualizerWordSource(title: 'Snow Halation', lyricsSnippet: ' '),
        'Snow Halation',
      );
      expect(buildAiMusicVisualizerThemeSystemPrompt(), contains('wordColors'));
    });
  });

  test('一次 complete 往返：回复经校验落成主题', () async {
    late Map<String, Object?> sent;
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'content': '```json\n${jsonEncode(_dual())}\n```',
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    final AiMusicVisualizerTheme? t = await requestAiMusicVisualizerTheme(
      client: client,
      provider: AiProviderConfig(
        id: 'p',
        presetId: kAiCustomPresetId,
        name: 'p',
        baseUrl: Uri.parse('https://example.com/v1'),
        apiKey: 'k',
        model: 'm',
        protocol: AiWireProtocol.openAiCompatible,
      ),
      title: 'T',
      artist: 'A',
      lyricsSnippet: _lyrics,
      uiLanguage: 'en',
    );
    expect(t, isNotNull);
    expect(t!.intensity, LyricVisualizerIntensity.calm);
    expect(jsonEncode(sent), contains('夜空に光る星'));
  });
}

// 反馈修复进度（契约第 6 节）：按用户当前更新通道 + 本机平台 + 本机版本，算出该给反馈人
// 看哪句话。版本比较复用更新器判据；本机构建属于哪个通道由版本串判定，跨通道不比较。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_fix_progress.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';

const int _now = 1760000000000;
const int _hour = 3600 * 1000;

FeedbackFix _fix({
  String scope = 'app',
  int at = _now - 10 * _hour,
  Map<String, Map<String, String>> releases =
      const <String, Map<String, String>>{},
}) => FeedbackFix.tryParse(<String, dynamic>{
  'sha': '0123456789abcdef0123456789abcdef01234567',
  'scope': scope,
  'at': at,
  'releases': <String, dynamic>{
    for (final MapEntry<String, Map<String, String>> ch in releases.entries)
      ch.key: <String, dynamic>{
        for (final MapEntry<String, String> pl in ch.value.entries)
          pl.key: <String, dynamic>{'version': pl.value, 'at': _now - _hour},
      },
  },
})!;

FeedbackFixProgress _progress(
  FeedbackFix fix, {
  UpdateChannel channel = UpdateChannel.stable,
  String? platform = 'android',
  String? local = '2.3.0',
  int now = _now,
}) => feedbackFixProgress(
  fix,
  channel: channel,
  platform: platform,
  localVersion: local,
  now: now,
);

void main() {
  group('不需要更新 App', () {
    test('scope none：无论有没有发布都直接说已生效', () {
      expect(_progress(_fix(scope: 'none')), isA<FeedbackFixNoUpdateNeeded>());
      expect(
        _progress(
          _fix(
            scope: 'none',
            releases: <String, Map<String, String>>{
              'debug': <String, String>{'android': '2.3.0-debug.5'},
            },
          ),
          platform: null,
          local: null,
        ),
        isA<FeedbackFixNoUpdateNeeded>(),
      );
    });
  });

  group('本机已包含（只和本机构建所属通道的那条发布比）', () {
    test('debug 构建：本机序号 >= 发布序号', () {
      final FeedbackFix fix = _fix(
        releases: <String, Map<String, String>>{
          'debug': <String, String>{'android': '2.3.0-debug.150'},
        },
      );
      for (final String local in <String>[
        '2.3.0-debug.150',
        '2.3.0-debug.200',
        '2.3.0-debug.200+200', // build metadata 不影响
        '2.4.0-debug.10', // 更高基版本
      ]) {
        final FeedbackFixProgress p = _progress(
          fix,
          channel: UpdateChannel.debug,
          local: local,
        );
        expect(p, isA<FeedbackFixInstalled>(), reason: local);
        expect((p as FeedbackFixInstalled).version, '2.3.0-debug.150');
      }
    });

    test('正式版构建：同版本或更高基版本已包含', () {
      final FeedbackFix fix = _fix(
        releases: <String, Map<String, String>>{
          'stable': <String, String>{'android': '2.3.0'},
        },
      );
      expect(_progress(fix, local: '2.3.0'), isA<FeedbackFixInstalled>());
      expect(_progress(fix, local: '2.3.1'), isA<FeedbackFixInstalled>());
    });

    test('本机通道看本机版本串而不是设置：设成正式版通道但装着含修复的调试版', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'debug': <String, String>{'android': '2.3.0-debug.150'},
          },
        ),
        channel: UpdateChannel.stable,
        local: '2.3.0-debug.160',
      );
      expect(p, isA<FeedbackFixInstalled>());
    });

    test('跨通道不比较：调试版构建不拿正式版的发布判已包含', () {
      // 本机 2.3.0-debug.999 的序号与正式版 2.3.0 无可比性，不能说「已包含」。
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'stable': <String, String>{'android': '2.3.0'},
          },
        ),
        channel: UpdateChannel.debug,
        local: '2.3.0-debug.999',
      );
      expect(p, isA<FeedbackFixUpdateAvailable>());
      expect((p as FeedbackFixUpdateAvailable).version, '2.3.0');
    });
  });

  group('当前通道已发布、本机还没装', () {
    test('本机旧版本：给「检查更新」', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'debug': <String, String>{'android': '2.3.0-debug.150'},
          },
        ),
        channel: UpdateChannel.debug,
        local: '2.3.0-debug.100',
      );
      expect(p, isA<FeedbackFixUpdateAvailable>());
      expect((p as FeedbackFixUpdateAvailable).version, '2.3.0-debug.150');
    });

    test('正式版：本机基版本低', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'stable': <String, String>{'android': '2.3.0'},
          },
        ),
        local: '2.2.9',
      );
      expect((p as FeedbackFixUpdateAvailable).version, '2.3.0');
    });

    test('测试版通道也收正式版：只有正式版发布时照样能更新到', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'stable': <String, String>{'android': '2.3.0'},
          },
        ),
        channel: UpdateChannel.beta,
        local: '2.2.0-beta.90',
      );
      expect((p as FeedbackFixUpdateAvailable).version, '2.3.0');
    });

    test('自己通道的发布优先于更保守通道的', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'stable': <String, String>{'android': '2.3.0'},
            'beta': <String, String>{'android': '2.3.0-beta.120'},
          },
        ),
        channel: UpdateChannel.beta,
        local: '2.2.0-beta.90',
      );
      expect((p as FeedbackFixUpdateAvailable).version, '2.3.0-beta.120');
    });
  });

  group('只有更快的通道发布了', () {
    test('正式版用户、调试版已发布：建议切到调试通道', () {
      final FeedbackFixProgress p = _progress(
        _fix(
          releases: <String, Map<String, String>>{
            'debug': <String, String>{'android': '2.3.0-debug.150'},
          },
        ),
        local: '2.2.0',
      );
      expect(p, isA<FeedbackFixFasterChannelOnly>());
      final FeedbackFixFasterChannelOnly f = p as FeedbackFixFasterChannelOnly;
      expect(f.current, UpdateChannel.stable);
      expect(f.channel, UpdateChannel.debug);
      expect(f.version, '2.3.0-debug.150');
    });

    test('正式版用户、调试版与测试版都发布了：最快的调试版优先', () {
      final FeedbackFixFasterChannelOnly f =
          _progress(
                _fix(
                  releases: <String, Map<String, String>>{
                    'beta': <String, String>{'android': '2.3.0-beta.120'},
                    'debug': <String, String>{'android': '2.3.0-debug.110'},
                  },
                ),
              )
              as FeedbackFixFasterChannelOnly;
      expect(f.channel, UpdateChannel.debug);
      expect(f.version, '2.3.0-debug.110');
    });

    test('正式版用户、只有测试版发布：建议切到测试通道', () {
      final FeedbackFixFasterChannelOnly f =
          _progress(
                _fix(
                  releases: <String, Map<String, String>>{
                    'beta': <String, String>{'android': '2.3.0-beta.120'},
                  },
                ),
              )
              as FeedbackFixFasterChannelOnly;
      expect(f.channel, UpdateChannel.beta);
    });

    test('测试版用户、只有调试版发布', () {
      final FeedbackFixFasterChannelOnly f =
          _progress(
                _fix(
                  releases: <String, Map<String, String>>{
                    'debug': <String, String>{'android': '2.3.0-debug.110'},
                  },
                ),
                channel: UpdateChannel.beta,
                local: '2.2.0-beta.90',
              )
              as FeedbackFixFasterChannelOnly;
      expect(f.current, UpdateChannel.beta);
      expect(f.channel, UpdateChannel.debug);
    });
  });

  group('都还没发布', () {
    test('调试通道且 3 小时内：正在打包；超过 3 小时：等待下个版本', () {
      expect(
        _progress(
          _fix(at: _now - _hour),
          channel: UpdateChannel.debug,
          local: '2.3.0-debug.1',
        ),
        isA<FeedbackFixPending>().having(
          (FeedbackFixPending p) => p.building,
          'building',
          isTrue,
        ),
      );
      final FeedbackFixPending late =
          _progress(
                _fix(at: _now - 4 * _hour),
                channel: UpdateChannel.debug,
                local: '2.3.0-debug.1',
              )
              as FeedbackFixPending;
      expect(late.building, isFalse);
      expect(late.channel, UpdateChannel.debug);
    });

    test('本机时钟比服务端慢（标记时刻在未来）也算刚标记', () {
      final FeedbackFixPending p =
          _progress(
                _fix(at: _now + 5 * 60 * 1000),
                channel: UpdateChannel.debug,
              )
              as FeedbackFixPending;
      expect(p.building, isTrue);
    });

    test('正式版 / 测试版通道刚标记也不说「正在打包」', () {
      for (final UpdateChannel c in <UpdateChannel>[
        UpdateChannel.stable,
        UpdateChannel.beta,
      ]) {
        final FeedbackFixPending p =
            _progress(_fix(at: _now - 60 * 1000), channel: c)
                as FeedbackFixPending;
        expect(p.building, isFalse, reason: c.name);
        expect(p.channel, c);
      }
    });

    test('别的平台发布了不算本平台发布', () {
      expect(
        _progress(
          _fix(
            releases: <String, Map<String, String>>{
              'stable': <String, String>{'windows': '2.3.0'},
              'debug': <String, String>{'macos': '2.3.0-debug.150'},
            },
          ),
        ),
        isA<FeedbackFixPending>(),
      );
    });

    test('本平台没有构建回填（platform null）：不说「等待下个版本」', () {
      for (final UpdateChannel channel in UpdateChannel.values) {
        for (final String? local in <String?>[null, '2.3.0', '2.3.0-debug.9']) {
          expect(
            _progress(
              _fix(
                at: _now - 1000,
                releases: <String, Map<String, String>>{
                  'stable': <String, String>{'android': '2.3.0'},
                },
              ),
              channel: channel,
              platform: null,
              local: local,
            ),
            isA<FeedbackFixPlatformNotTracked>(),
            reason: '$channel / $local',
          );
        }
      }
      // scope none 照旧说无需更新（与平台无关）。
      expect(
        _progress(_fix(scope: 'none'), platform: null),
        isA<FeedbackFixNoUpdateNeeded>(),
      );
    });

    test('发布条目的版本串不属于它所在的通道：当没有（跨通道不比较）', () {
      expect(
        _progress(
          _fix(
            releases: <String, Map<String, String>>{
              'debug': <String, String>{'android': '2.3.0'},
              'stable': <String, String>{'android': '2.3.0-debug.150'},
            },
          ),
          channel: UpdateChannel.debug,
          local: '2.3.0-debug.999',
        ),
        isA<FeedbackFixPending>(),
      );
    });
  });

  group('本机版本串缺失 / 未知', () {
    final FeedbackFix fix = _fix(
      releases: <String, Map<String, String>>{
        'stable': <String, String>{'android': '2.3.0'},
      },
    );

    test('null / 空串 / 空白：不判已包含，照常给更新', () {
      for (final String? local in <String?>[null, '', '   ']) {
        final FeedbackFixProgress p = _progress(fix, local: local);
        expect(p, isA<FeedbackFixUpdateAvailable>(), reason: '$local');
      }
    });

    test('认不出的版本串：不当成「已包含」', () {
      expect(
        _progress(fix, local: 'dev-build'),
        isA<FeedbackFixUpdateAvailable>(),
      );
    });
  });

  group('平台键只认官方发布回填的平台', () {
    test('四个回填平台原样返回；Linux / 未知平台为 null', () {
      for (final String os in <String>['android', 'windows', 'macos', 'ios']) {
        expect(feedbackPlatformKeyFor(os), os);
      }
      for (final String os in <String>['linux', 'fuchsia', '']) {
        expect(feedbackPlatformKeyFor(os), isNull, reason: os);
      }
    });

    test('本机平台键与纯函数同口径', () {
      expect(
        feedbackPlatformKey(),
        feedbackPlatformKeyFor(Platform.operatingSystem),
      );
    });

    test('与发布 workflow 的回填步骤一致（加 / 减回填平台要同步改这里）', () {
      final RegExp platformLine = RegExp(
        r'^\s*PLATFORM:\s*([a-z]+)\s*$',
        multiLine: true,
      );
      final Set<String> backfilled = <String>{};
      for (final String path in <String>[
        '../.github/workflows/release.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '缺 ${f.absolute.path}');
        backfilled.addAll(
          platformLine
              .allMatches(f.readAsStringSync())
              .map((RegExpMatch m) => m.group(1)!),
        );
      }
      expect(backfilled, kFeedbackReleasePlatforms);
    });
  });
}

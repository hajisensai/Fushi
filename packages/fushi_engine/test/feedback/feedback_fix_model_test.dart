// 反馈修复的线格式（契约：services/leaderboard/src/feedback.js 的 summary().fix）：
// fix 为 null 或 {sha, scope, at, releases: channel → platform → {version, at}}。
// 解析对缺字段 / 未知值宽容：坏条目丢掉，不认识的 scope 按 app，不认识的通道 / 平台原样保留。

import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:test/test.dart';

Map<String, dynamic> _summary([Object? fix]) => <String, dynamic>{
  'id': 'abcdefghij',
  'category': 'bug',
  'title': 't',
  'status': 'resolved',
  'createdAt': 1,
  'updatedAt': 2,
  'fix': ?fix,
};

const String _sha = '0123456789abcdef0123456789abcdef01234567';

void main() {
  test('完整的 fix 解析到摘要与详情', () {
    final Map<String, dynamic> fix = <String, dynamic>{
      'sha': _sha,
      'scope': 'app',
      'at': 1760000000000,
      'releases': <String, dynamic>{
        'debug': <String, dynamic>{
          'android': <String, dynamic>{
            'version': '2.3.0-debug.12345',
            'at': 1760000001000,
          },
          'windows': <String, dynamic>{
            'version': '2.3.0-debug.12346',
            'at': 1760000002000,
          },
        },
        'beta': <String, dynamic>{},
        'stable': <String, dynamic>{},
      },
    };
    final FeedbackSummary s = FeedbackSummary.fromJson(_summary(fix));
    final FeedbackFix f = s.fix!;
    expect(f.sha, _sha);
    expect(f.shortSha, '0123456');
    expect(f.scope, FeedbackFixScope.app);
    expect(f.at, 1760000000000);
    expect(f.release('debug', 'android')!.version, '2.3.0-debug.12345');
    expect(f.release('debug', 'android')!.at, 1760000001000);
    expect(f.release('debug', 'windows')!.version, '2.3.0-debug.12346');
    expect(f.release('stable', 'android'), isNull);
    // 空通道不留空壳。
    expect(f.releases.keys, <String>['debug']);

    final FeedbackDetail d = FeedbackDetail.fromJson(<String, dynamic>{
      ..._summary(fix),
      'body': 'b',
      'attachments': <Object>[],
      'messages': <Object>[],
    });
    expect(d.fix!.release('debug', 'android')!.version, '2.3.0-debug.12345');
  });

  test('fix 缺失 / null / 不是对象 → null', () {
    expect(FeedbackSummary.fromJson(_summary()).fix, isNull);
    expect(
      FeedbackSummary.fromJson(<String, dynamic>{
        ..._summary(),
        'fix': null,
      }).fix,
      isNull,
    );
    expect(FeedbackSummary.fromJson(_summary('oops')).fix, isNull);
    expect(FeedbackSummary.fromJson(_summary(<Object>[1])).fix, isNull);
  });

  test('scope：none 认得；未知 / 缺失按 app（宁可让用户去更新）', () {
    FeedbackFix parse(Object? scope) =>
        FeedbackFix.tryParse(<String, dynamic>{'sha': _sha, 'scope': ?scope})!;
    expect(parse('none').scope, FeedbackFixScope.none);
    expect(parse('app').scope, FeedbackFixScope.app);
    expect(parse('server_only').scope, FeedbackFixScope.app);
    expect(parse(null).scope, FeedbackFixScope.app);
    expect(parse(3).scope, FeedbackFixScope.app);
  });

  test('缺字段取缺省；releases 缺失当空；坏条目丢掉、未知通道 / 平台保留', () {
    final FeedbackFix bare = FeedbackFix.tryParse(<String, dynamic>{})!;
    expect(bare.sha, '');
    expect(bare.shortSha, '');
    expect(bare.at, 0);
    expect(bare.releases, isEmpty);

    final FeedbackFix f = FeedbackFix.tryParse(<String, dynamic>{
      'sha': _sha,
      'at': 'yesterday',
      'releases': <String, dynamic>{
        'debug': <String, dynamic>{
          'android': <String, dynamic>{'version': '2.3.0-debug.1'}, // 没 at
          'ios': <String, dynamic>{'at': 5}, // 没版本：丢
          'macos': <String, dynamic>{'version': ''}, // 空版本：丢
          'windows': 'broken', // 不是对象：丢
          'linux': <String, dynamic>{'version': 12, 'at': 5}, // 版本不是串：丢
        },
        'nightly': <String, dynamic>{
          'android': <String, dynamic>{'version': '9.9.9', 'at': 1},
        },
        'beta': 'broken',
      },
    })!;
    expect(f.at, 0);
    expect(f.releases.keys.toSet(), <String>{'debug', 'nightly'});
    expect(f.releases['debug']!.keys, <String>['android']);
    expect(f.release('debug', 'android')!.at, 0);
    expect(f.release('nightly', 'android')!.version, '9.9.9');

    expect(
      FeedbackFix.tryParse(<String, dynamic>{
        'sha': _sha,
        'releases': 'broken',
      })!.releases,
      isEmpty,
    );
  });

  test('toJson 往返不丢信息（本机回执文件存的就是这一份）', () {
    final FeedbackFix f = FeedbackFix.tryParse(<String, dynamic>{
      'sha': _sha,
      'scope': 'none',
      'at': 7,
      'releases': <String, dynamic>{
        'stable': <String, dynamic>{
          'android': <String, dynamic>{'version': '2.3.0', 'at': 9},
        },
      },
    })!;
    final FeedbackFix back = FeedbackFix.tryParse(f.toJson())!;
    expect(back.sha, _sha);
    expect(back.scope, FeedbackFixScope.none);
    expect(back.at, 7);
    expect(back.release('stable', 'android')!.version, '2.3.0');
    expect(back.release('stable', 'android')!.at, 9);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/features/study/web_card_source.dart';
import 'package:fushi/src/web_browser/features/study/web_study_script.dart';
import 'package:fushi/src/web_browser/features/study/web_study_session.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

class FakeClock implements WebStudyClockPort {
  FakeClock(this.key, this.title);

  final String key;
  final String title;
  final List<String> log = <String>[];
  int chars = 0;

  @override
  void start() => log.add('start');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  void detach() => log.add('detach');

  @override
  void touch() => log.add('touch');

  @override
  void addChars(int c) => chars += c;
}

WebStudyReport report({
  bool visible = true,
  bool interacted = true,
  bool ja = true,
  int chars = 0,
}) => (visible: visible, interacted: interacted, japanese: ja, chars: chars);

void main() {
  group('webStudyMediaKey', () {
    test('主机小写、去片段与末尾斜杠、保留查询串', () {
      expect(
        webStudyMediaKey(Uri.parse('https://Kakuyomu.JP/works/1/?a=1#p')),
        'web:kakuyomu.jp/works/1?a=1',
      );
      expect(webStudyMediaKey(Uri.parse('http://a.jp/')), 'web:a.jp');
    });

    test('非 http(s) 不计', () {
      expect(webStudyMediaKey(Uri.parse('about:blank')), isNull);
      expect(webStudyMediaKey(Uri.parse('file:///c/x.html')), isNull);
      expect(webStudyMediaKey(null), isNull);
    });
  });

  test('webStudyClockMayRun 五条缺一不可', () {
    bool run({
      bool tab = true,
      bool app = true,
      bool vis = true,
      bool ja = true,
      bool act = true,
    }) => webStudyClockMayRun(
      tabActive: tab,
      appForeground: app,
      pageVisible: vis,
      japanesePage: ja,
      interacted: act,
    );
    expect(run(), isTrue);
    expect(run(tab: false), isFalse);
    expect(run(app: false), isFalse);
    expect(run(vis: false), isFalse);
    expect(run(ja: false), isFalse);
    expect(run(act: false), isFalse);
  });

  test('parseWebStudyReport：字数夹到上限、负数归零、形状不对为 null', () {
    final WebStudyReport? r = parseWebStudyReport(<dynamic>[
      <String, Object>{
        'visible': true,
        'interacted': true,
        'ja': true,
        'chars': 999999,
      },
    ]);
    expect(r?.chars, kWebStudyMaxCharsPerReport);
    expect(
      parseWebStudyReport(<dynamic>[
        <String, Object>{'chars': -5},
      ])?.chars,
      0,
    );
    expect(parseWebStudyReport(<dynamic>['x']), isNull);
  });

  group('WebStudySession', () {
    late List<FakeClock> clocks;
    WebStudySession session({bool incognito = false}) {
      clocks = <FakeClock>[];
      return WebStudySession(
        incognito: incognito,
        clockFactory: ({required String mediaKey, required String title}) {
          final FakeClock c = FakeClock(mediaKey, title);
          clocks.add(c);
          return c;
        },
      );
    }

    test('只加载不交互不开钟；首次交互开钟、走表、记字数', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(interacted: false), title: 'T');
      expect(clocks, isEmpty);
      s.report(report(chars: 30), title: 'T');
      expect(clocks.single.key, 'web:a.jp/1');
      expect(clocks.single.title, 'T');
      expect(clocks.single.log, <String>['start', 'touch']);
      expect(clocks.single.chars, 30);
      expect(s.running, isTrue);
    });

    test('非日文页不计', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.com/'));
      s.report(report(ja: false, chars: 10), title: 'T');
      expect(clocks, isEmpty);
    });

    test('切到后台标签页 / app 退后台 / 页面隐藏都停表，回来续表', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(), title: 'T');
      final FakeClock c = clocks.single;
      s.setTabActive(false);
      s.setTabActive(true);
      s.setAppForeground(false);
      s.setAppForeground(true);
      s.report(report(visible: false, interacted: false), title: 'T');
      s.report(report(), title: 'T');
      expect(c.log, <String>[
        'start',
        'touch',
        'stop',
        'start',
        'stop',
        'start',
        'stop',
        'start',
        'touch',
      ]);
    });

    test('停表期间上报的字数不入账', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(), title: 'T');
      s.setTabActive(false);
      s.report(report(chars: 50, interacted: false), title: 'T');
      expect(clocks.single.chars, 0);
    });

    test('换页封旧钟，新页要重新交互', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(), title: 'T');
      await s.navigate(Uri.parse('https://a.jp/1#frag'));
      expect(clocks.single.log.last, 'touch');
      await s.navigate(Uri.parse('https://a.jp/2'));
      expect(clocks.single.log.last, 'stop');
      s.report(report(interacted: false), title: 'U');
      expect(clocks, hasLength(1));
      s.report(report(), title: 'U');
      expect(clocks.last.key, 'web:a.jp/2');
    });

    test('无痕标签页永不开钟', () async {
      final WebStudySession s = session(incognito: true)..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(chars: 10), title: 'T');
      expect(clocks, isEmpty);
    });

    test('detach 零 IO 结算', () async {
      final WebStudySession s = session()..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report(report(), title: 'T');
      s.detach();
      expect(clocks.single.log.last, 'detach');
      expect(s.running, isFalse);
    });
  });

  test('页内脚本：幂等守卫 + handler 名 + 常量', () {
    final String js = webStudyInstallSource();
    expect(js, contains('if (window.__fushiStudy) return;'));
    expect(js, contains("'$kWebStudyHandler'"));
    expect(js, contains('FLUSH_MS = $kWebStudyFlushMs'));
    expect(js, contains('JA_MIN = $kWebStudyJapaneseMinChars'));
  });

  group('卡片来源', () {
    test('标题 + 去片段网址；无痕 / 非 http(s) 为 null', () {
      final WebBrowserTab tab = WebBrowserTab(
        id: '1',
        url: Uri.parse('https://a.jp/x?y=1#z'),
        title: '記事',
      );
      final WebBrowserCardSource? src = webBrowserCardSourceOf(tab);
      expect(src?.title, '記事');
      expect(src?.url.toString(), 'https://a.jp/x?y=1');
      expect(
        webBrowserCardSourceOf(
          WebBrowserTab(
            id: '2',
            url: Uri.parse('https://a.jp'),
            incognito: true,
          ),
        ),
        isNull,
      );
      expect(
        webBrowserCardSourceOf(
          WebBrowserTab(id: '3', url: Uri.parse('about:blank')),
        ),
        isNull,
      );
    });

    test('source-link HTML 转义', () {
      final WebBrowserCardSource src = WebBrowserCardSource(
        title: '<A&B>',
        url: Uri.parse('https://a.jp/?q="x"'),
      );
      expect(
        src.toSourceLinkHtml(),
        '<a href="https://a.jp/?q=%22x%22">&lt;A&amp;B&gt;</a>',
      );
    });
  });
}

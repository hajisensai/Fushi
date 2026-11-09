import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:test/test.dart';

/// 管理页「词典」页：导航项、页面 section 与词典端点（清单 / 默认开关 / 词典语言 /
/// 删除 / 重载）都接在 `adminWebUiHtml` 里。端点本身的行为见 `admin_dictionaries_test.dart`；
/// 中英文覆盖由 `web_ui_i18n_test.dart` 统一守。
void main() {
  test('导航里「词典」紧跟在「库」之后，有对应的 section 与列表', () {
    final int libraries = adminWebUiHtml.indexOf('<button data-s="libraries">');
    final int dictionaries = adminWebUiHtml.indexOf(
      '<button data-s="dictionaries">',
    );
    final int upload = adminWebUiHtml.indexOf('<button data-s="upload">');
    expect(libraries, isNonNegative);
    expect(dictionaries, greaterThan(libraries));
    expect(upload, greaterThan(dictionaries));
    expect(
      adminWebUiHtml.substring(libraries + 1, dictionaries),
      isNot(contains('<button ')),
      reason: '「库」与「词典」之间不该夹别的导航项',
    );
    expect(
      adminWebUiHtml,
      contains(
        '<button data-s="dictionaries"><span class="ind"><svg class="i">'
        '<use href="#i-dictionaries"/></svg></span><span class="lbl">词典</span>'
        '</button>',
      ),
    );
    expect(adminWebUiHtml, contains('<symbol id="i-dictionaries"'));
    expect(adminWebUiHtml, contains('<section id="s-dictionaries">'));
    expect(adminWebUiHtml, contains('<div class="list" id="dicts">'));
    expect(adminWebUiHtml, contains('id="btn-dict-reload"'));
  });

  test('清单只在进页 / 操作后拉，不跟 2.5 秒轮询（统计占用要遍历目录）', () {
    expect(
      adminWebUiHtml,
      contains(
        'dictionaries:async()=>{ if(!dictsLoaded) await loadDictionaries(); }',
      ),
    );
    expect(
      adminWebUiHtml,
      contains("if (s==='dictionaries') dictsLoaded=false;"),
    );
  });

  test('词典页接上 admin API 的词典端点', () {
    expect(adminWebUiHtml, contains("api('dictionaries')"));
    expect(
      adminWebUiHtml,
      contains(
        "put('dictionaries/'+encodeURIComponent(c.dataset.dictDefault), "
        '{defaultEnabled:on})',
      ),
    );
    expect(
      adminWebUiHtml,
      contains(
        "put('dictionaries/'+encodeURIComponent(name), "
        '{languageOverride: value || null})',
      ),
    );
    expect(
      adminWebUiHtml,
      contains("del('dictionaries/'+encodeURIComponent(b.dataset.dictDel))"),
    );
    expect(adminWebUiHtml, contains("post('dictionaries/reload')"));
  });

  test('删除走页内确认对话框（危险样式），不用 window.confirm', () {
    expect(
      adminWebUiHtml,
      contains(
        "if(!await ask(T('删除词典「{0}」？会删掉服务端的词典文件，"
        "已配置它的设备将查不到它。', b.dataset.label), true)) return;",
      ),
    );
    expect(adminWebUiHtml, isNot(contains('confirm(')));
  });

  test('语言下拉：自动（包内声明）+ app 的常用标签 + 自定义', () {
    expect(adminWebUiHtml, contains("T('自动（包内声明：{0}）'"));
    expect(adminWebUiHtml, contains("T('自动（包内未声明）')"));
    for (final String code in <String>[
      'ja',
      'zh-Hans',
      'zh-Hant',
      'ko',
      'en',
    ]) {
      expect(adminWebUiHtml, contains("['$code',T("), reason: code);
    }
    expect(adminWebUiHtml, contains("['__other', T('其他…')]"));
    expect(
      adminWebUiHtml,
      contains('const LANG_TAG_RE = /^[A-Za-z0-9-]{2,35}\$/;'),
    );
  });

  test('说明默认开关只管不带配置选择的请求，并标出文件缺失', () {
    expect(adminWebUiHtml, contains('「默认启用」只对不携带配置词典选择的请求生效'));
    expect(adminWebUiHtml, contains("tag('err', T('文件缺失'))"));
  });
}

import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:test/test.dart';

/// 管理页「词典」页：导航按钮、页面 section 与四个词典端点（清单 / 默认开关 / 删除 /
/// 重载）都接在 `adminWebUiHtml` 里。端点本身的行为见 `admin_dictionaries_test.dart`。
void main() {
  test('管理页有「词典」页，位于「库」之后', () {
    expect(
      adminWebUiHtml,
      contains(
        '<button data-s="libraries">库</button>'
        '<button data-s="dictionaries">词典</button>',
      ),
    );
    expect(adminWebUiHtml, contains('<section id="s-dictionaries">'));
    expect(adminWebUiHtml, contains('<tbody id="dicts">'));
    expect(
      adminWebUiHtml,
      contains('dictionaries:()=>loadDictionaries(false)'),
    );
  });

  test('词典页接上 admin API 的四个词典端点', () {
    expect(adminWebUiHtml, contains("api('dictionaries')"));
    expect(
      adminWebUiHtml,
      contains(
        "put('dictionaries/'+encodeURIComponent(c.dataset.dictDefault),"
        '{defaultEnabled:on})',
      ),
    );
    expect(
      adminWebUiHtml,
      contains("del('dictionaries/'+encodeURIComponent(b.dataset.dictDel))"),
    );
    expect(adminWebUiHtml, contains("post('dictionaries/reload')"));
  });

  test('词典页说明默认开关只管不带配置选择的请求，并标出文件缺失', () {
    expect(adminWebUiHtml, contains('「默认启用」只对不携带配置词典选择的请求生效'));
    expect(adminWebUiHtml, contains('文件缺失'));
  });
}

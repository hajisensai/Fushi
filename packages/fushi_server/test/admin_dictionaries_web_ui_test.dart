import 'package:fushi_server/src/admin/admin_dictionary_import.dart';
import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:fushi_server/src/admin/web_ui_en.dart';
import 'package:test/test.dart';

/// 管理页「词典」页（只有一个页面）：接的是 `admin_dictionaries.dart` 那一套 admin 词典契约
/// （GET 清单 / PUT 导入 / PUT order / PATCH / DELETE / POST reload / GET lookup）。端点本身的
/// 行为见 `admin_dictionaries_test.dart`；中英文覆盖由 `web_ui_i18n_test.dart` 统一守。
void main() {
  String dictionariesSection() {
    final int start = adminWebUiHtml.indexOf('<section id="s-dictionaries">');
    final int end = adminWebUiHtml.indexOf('</section>', start);
    expect(start, isNonNegative);
    return adminWebUiHtml.substring(start, end);
  }

  test('只有一个「词典」页：一个导航项、一个 section、一套 loadDictionaries', () {
    expect(
      '<button class="nav-item" data-s="dictionaries">'.allMatches(
        adminWebUiHtml,
      ),
      hasLength(1),
    );
    expect(
      '<section id="s-dictionaries">'.allMatches(adminWebUiHtml),
      hasLength(1),
    );
    expect(
      'data-fushi-icon="dictionary"'.allMatches(adminWebUiHtml),
      hasLength(1),
    );
    expect(
      'async function loadDictionaries('.allMatches(adminWebUiHtml),
      hasLength(1),
    );
    expect(
      'function uploadDictionary('.allMatches(adminWebUiHtml),
      hasLength(1),
    );
    expect('const DICT_TYPE'.allMatches(adminWebUiHtml), hasLength(1));
    final String section = dictionariesSection();
    expect(
      section,
      contains('<div class="setting-list is-surface" id="dicts">'),
    );
    expect(section, contains('id="btn-dict-reload"'));
    expect(section, contains('id="dict-q"'));
  });

  test('清单只在进页 / 操作后拉，不跟 2.5 秒轮询（统计占用要遍历目录，行里有就地编辑）', () {
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

  test('改动走统一契约：PATCH / PUT order / DELETE / POST reload，回包直接重绘', () {
    expect(adminWebUiHtml, contains("api('dictionaries')"));
    expect(
      adminWebUiHtml,
      contains(
        "const patchDict = (name, body) => api('dictionaries/'+"
        "encodeURIComponent(name), {method:'PATCH', body:JSON.stringify(body)});",
      ),
    );
    expect(
      adminWebUiHtml,
      contains('patchDict(c.dataset.dictDefault, {defaultEnabled:on})'),
    );
    expect(
      adminWebUiHtml,
      contains('patchDict(name, {languageOverride: v || null})'),
    );
    expect(
      adminWebUiHtml,
      contains('patchDict(name, {displayName: v || null})'),
    );
    expect(
      adminWebUiHtml,
      contains("renderDictionaries(await put('dictionaries/order',{names}))"),
    );
    expect(
      adminWebUiHtml,
      contains("del('dictionaries/'+encodeURIComponent(b.dataset.drm))"),
    );
    expect(adminWebUiHtml, contains("post('dictionaries/reload')"));
    // 旧的平行契约（POST import / PUT dictionaries/<名> / engineAvailable）不得再出现。
    expect(adminWebUiHtml, isNot(contains('/api/admin/dictionaries/import')));
    expect(adminWebUiHtml, isNot(contains("put('dictionaries/'+")));
    expect(adminWebUiHtml, isNot(contains('engineAvailable')));
    expect(adminWebUiHtml, isNot(contains('data-hide=')));
  });

  test('删除走页内确认对话框（危险样式），不用 window.confirm', () {
    expect(
      adminWebUiHtml,
      contains(
        "if(!await ask(T('删除词典「{0}」？会删掉服务端上的词典文件，"
        "用它查词的设备将查不到它（不影响各设备本地的词典）。', b.dataset.label), true)) return;",
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
    expect(dictionariesSection(), contains('「默认启用」只对不携带配置词典选择的请求生效'));
    expect(adminWebUiHtml, contains("tag('err', T('文件缺失'))"));
    expect(adminWebUiHtml, contains('data-dict-default="'));
  });

  test('导入：accept 与服务端收的扩展名一致，PUT 带 ?filename=', () {
    expect(
      dictionariesSection(),
      contains('accept="${kDictionaryImportExtensions.join(',')}"'),
    );
    expect(
      adminWebUiHtml,
      contains(
        "x.open('PUT', '/api/admin/dictionaries?filename='"
        '+encodeURIComponent(file.name));',
      ),
    );
    expect(adminWebUiHtml, contains('x.upload.onprogress'));
    expect(adminWebUiHtml, contains('x.send(file);'));
  });

  test('显示名就地编辑：铅笔 → 文本框，回车 / 失焦保存，Esc 取消，留空或填回原名 = 清掉', () {
    expect(
      adminWebUiHtml,
      contains(
        '<button class="icon-button is-small" data-dict-rename="\${esc(d.name)}" '
        "title=\"\${esc(T('修改显示名'))}\" aria-label=\"\${esc(T('修改显示名'))}\">"
        "\${icon('edit')}</button>",
      ),
    );
    expect(adminWebUiHtml, contains("edit:'edit'"));
    expect(adminWebUiHtml, contains("if (v===name) v='';"));
    expect(
      adminWebUiHtml,
      contains(
        "else if(ev.key==='Escape'){ ev.preventDefault(); close(); b.focus(); }",
      ),
    );
    expect(adminWebUiHtml, contains('input.onblur = submit;'));
    // 隐藏属性要压过 .icon-button 的 display:grid。
    expect(adminWebUiHtml, contains('[hidden]{display:none!important}'));
  });

  test('新文案都有英文', () {
    for (final String key in <String>[
      '重新装载引擎',
      '词典包',
      '默认启用',
      '词典语言',
      '修改显示名',
      '显示名',
      '回车保存，Esc 取消，留空恢复原名',
      '显示名已改为「{0}」',
      '已恢复原名',
      '已重新装载，{0} 本',
      '先选择一个词典文件',
    ]) {
      expect(kWebUiEnglish[key], isNotNull, reason: key);
    }
  });
}

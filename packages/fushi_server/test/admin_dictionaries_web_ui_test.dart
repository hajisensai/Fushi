import 'package:fushi_server/src/admin/admin_dictionary_import.dart';
import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:fushi_server/src/admin/web_ui_en.dart';
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

  String dictionariesSection() {
    final int start = adminWebUiHtml.indexOf('<section id="s-dictionaries">');
    final int end = adminWebUiHtml.indexOf('</section>', start);
    expect(start, isNonNegative);
    return adminWebUiHtml.substring(start, end);
  }

  test('「导入词典」按钮 + 文件选择器在词典页，accept 与服务端收的扩展名一致', () {
    final String section = dictionariesSection();
    expect(
      section,
      contains(
        '<button class="b" id="btn-dict-import"><svg class="i">'
        '<use href="#i-upload"/></svg>导入词典</button>',
      ),
    );
    expect(
      section,
      contains(
        '<input type="file" id="dict-import-file" '
        'accept="${kDictionaryImportExtensions.join(',')}" hidden>',
      ),
    );
    expect(kDictionaryImportExtensions.join(','), '.zip,.fushidict,.mdx,.dsl');
    expect(
      section,
      contains('<div class="list" id="dict-import-state" hidden>'),
    );
  });

  test('导入：XHR 整文件 POST 到导入端点（带上传进度），完成后 toast + 重拉清单', () {
    expect(
      adminWebUiHtml,
      contains(
        "x.open('POST', '/api/admin/dictionaries/import?filename='"
        '+encodeURIComponent(file.name));',
      ),
    );
    expect(
      adminWebUiHtml,
      contains(
        "x.setRequestHeader('Content-Type', 'application/octet-stream');",
      ),
    );
    expect(adminWebUiHtml, contains('x.upload.onprogress'));
    expect(adminWebUiHtml, contains('x.send(file);'));
    expect(
      adminWebUiHtml,
      contains(
        "\$('#btn-dict-import').onclick = ()=>\$('#dict-import-file').click();",
      ),
    );
    expect(
      adminWebUiHtml,
      contains(
        "toast(r.replaced ? T('已更新词典「{0}」', r.name) : "
        "T('已导入词典「{0}」', r.name));\n    await loadDictionaries();",
      ),
    );
    // 上传中禁用按钮，任何出口都恢复；失败把原因留在进度行上并经 guard 弹错误 toast。
    expect(adminWebUiHtml, contains('btn.disabled=true; box.hidden=false;'));
    expect(adminWebUiHtml, contains('}finally{ btn.disabled=false; }'));
    expect(
      adminWebUiHtml,
      contains("\$('#dict-import-file').onchange = guard(async()=>{"),
    );
    expect(adminWebUiHtml, contains("st.textContent = T('导入中…');"));
  });

  test('显示名就地编辑：铅笔 → 文本框，回车 / 失焦保存，Esc 取消，留空或填回原名 = 清掉', () {
    expect(
      adminWebUiHtml,
      contains(
        '<button class="icon-btn sm" data-dict-rename="\${esc(d.name)}" '
        "title=\"\${esc(T('修改显示名'))}\" aria-label=\"\${esc(T('修改显示名'))}\">"
        "\${icon('edit')}</button>",
      ),
    );
    expect(
      adminWebUiHtml,
      contains(
        '<input type="text" class="dict-name-edit" '
        'data-dict-name-edit="\${esc(d.name)}" '
        "data-current=\"\${esc(d.displayName||'')}\" maxlength=\"200\" "
        'placeholder="\${esc(d.name)}"',
      ),
    );
    expect(adminWebUiHtml, contains('<symbol id="i-edit"'));
    expect(
      adminWebUiHtml,
      contains(
        "put('dictionaries/'+encodeURIComponent(name), "
        '{displayName: value || null})',
      ),
    );
    expect(adminWebUiHtml, contains("if (v===name) v='';"));
    expect(
      adminWebUiHtml,
      contains("if(e.key==='Enter'){ e.preventDefault(); submit(); }"),
    );
    expect(
      adminWebUiHtml,
      contains(
        "else if(e.key==='Escape'){ e.preventDefault(); close(); b.focus(); }",
      ),
    );
    expect(adminWebUiHtml, contains('input.onblur = submit;'));
    // 有覆盖名时真名另起一行 mono 显示。
    expect(
      adminWebUiHtml,
      contains(
        "\${label!==d.name?`<div class=\"s mono\">\${esc(d.name)}</div>`:''}",
      ),
    );
    // 隐藏属性要压过 .icon-btn 的 display:grid。
    expect(
      adminWebUiHtml,
      contains(
        '.icon-btn[hidden],input.dict-name-edit[hidden],.list[hidden]{display:none}',
      ),
    );
  });

  test('导入 / 改名的新文案都有英文', () {
    for (final String key in <String>[
      '导入词典',
      '导入中…',
      '上传中 {0} / {1}',
      '已导入词典「{0}」',
      '已更新词典「{0}」',
      '网络错误',
      '修改显示名',
      '显示名',
      '回车保存，Esc 取消，留空恢复原名',
      '显示名已改为「{0}」',
      '已恢复原名',
    ]) {
      expect(kWebUiEnglish[key], isNotNull, reason: key);
    }
    expect(adminWebUiHtml, isNot(contains('fushi_server dict import')));
  });
}

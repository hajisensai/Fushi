import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';

/// 复习时编辑的页内选区脚本：交给宿主的选中文字必须与「第几处」同口径——都去掉
/// 注音 `<rt>` / `<rp>`。Chromium 的 `Selection.toString()` 会带上读音（选「漢字」
/// 得到「漢かん字じ」），用它回传的话，带来源注音的字段一律对不上 srsFieldMatchText，
/// 加粗 / 高亮 / AI 改写都提示找不到。
///
/// 跑的是 [kSrsCardEditSelectionScript] 原文，DOM 用最小替身：片段按节点列表算
/// textContent，`querySelectorAll('rt,rp,…')` 返回可 `remove()` 的注音节点。
void main() {
  test('选中带注音的文字：回传去掉读音的文字与按同一口径数出的序号', () async {
    const String js =
        '''
const assert=require('node:assert/strict');
function frag(nodes){
  const list=nodes.map(n=>({...n}));
  return {
    querySelectorAll(sel){
      const tags=sel.split(',');
      return list.filter(n=>tags.includes(n.tag)).map(n=>({remove(){ list.splice(list.indexOf(n),1); }}));
    },
    get textContent(){ return list.map(n=>n.text).join(''); },
  };
}
const selected=[{tag:'#text',text:'漢'},{tag:'rt',text:'かん'},{tag:'#text',text:'字'},{tag:'rt',text:'じ'}];
const before=[{tag:'#text',text:'漢'},{tag:'rt',text:'かん'},{tag:'#text',text:'字の'}];
let sent=null, onChange=null;
globalThis.window={
  getSelection(){ return {rangeCount:1,isCollapsed:false,
    toString(){ return '漢かん字じ'; },
    getRangeAt(){ return {startContainer:{},startOffset:0,cloneContents:()=>frag(selected)}; }}; },
  flutter_inappwebview:{callHandler(name,payload){ sent={name,payload:JSON.parse(payload)}; }},
};
globalThis.document={body:{},
  createRange(){ return {setStart(){},setEnd(){},cloneContents:()=>frag(before)}; },
  addEventListener(type,fn){ if(type==='selectionchange') onChange=fn; },
};
globalThis.setTimeout=(fn)=>{ fn(); return 1; };
globalThis.clearTimeout=()=>{};
$kSrsCardEditSelectionScript
onChange();
assert.equal(sent.name,'$kSrsEditSelectionHandler');
assert.equal(sent.payload.text,'漢字','回传文字不带注音读音');
assert.equal(sent.payload.occ,1,'前文里同样的文字出现一次（同样去掉注音数）');
''';
    final Directory dir = Directory.systemTemp.createTempSync('srs-edit-sel-');
    try {
      final File script = File('${dir.path}/verify.js')..writeAsStringSync(js);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

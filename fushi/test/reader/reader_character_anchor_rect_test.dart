import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

void main() {
  test('production character geometry rejects empty WebKit caret origins', () {
    final String shell = ReaderPaginationScripts.paginatedShellSource();
    // BUG-3431：characterAnchorRect 在空 caret 盒时委托给 characterGlyphRect（量起点那个字
    // 自己的字形盒），两者要一起取出来跑；只取前者会在 node 里撞 `not a function`。
    String property(String name) {
      final int start = shell.indexOf('$name: function(range) {');
      final int end = shell.indexOf('\n  },', start);
      expect(start, isNonNegative, reason: '$name missing from the shell');
      expect(end, greaterThan(start));
      return shell.substring(start, end + 4);
    }

    final String object =
        '{${property('characterAnchorRect')},\n'
        '${property('characterGlyphRect')}}';
    final ProcessResult result = Process.runSync('node', <String>[
      '-e',
      'const shell = ($object);\n'
          'const measure = shell.characterAnchorRect.bind(shell);\n$_checks',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout.toString().trim(), 'OK');
  });

  test('both scroll modes use shared geometry before scrolling', () {
    final String paged = ReaderPaginationScripts.paginatedShellSource();
    final String continuous = ReaderPaginationScripts.continuousShellSource();
    expect(paged, contains('var rect = this.characterAnchorRect(range);'));
    // BUG-3431：连续模式先对齐目标字自己的字形盒（软换行处塌缩光标归上一列末），量不到
    // 才退回 caret 几何；两者都是 shell 共享的同一套几何 helper。
    expect(
      continuous,
      contains(
        'var rect = this.characterGlyphRect(startRange) ||\n'
        '        this.characterAnchorRect(startRange);',
      ),
    );
    expect(
      continuous,
      contains('endRange ? this.characterAnchorRect(endRange) : null'),
    );
    expect(continuous, contains('rect.right - targetX'));
  });
}

const String _checks = r'''
const assert = require('node:assert/strict');
const empty = {left:0,top:0,width:0,height:0};
const glyph = {left:358,right:383,top:3376,width:25,height:22};
function caret(text, offset, rect=empty, boxes=[empty,glyph]) {
  let end = null;
  const node = {nodeType:3,textContent:text};
  const range = {
    startContainer:node,startOffset:offset,
    getBoundingClientRect:()=>rect,
    cloneRange:()=>({
      setStart:(n,i)=>{ assert.equal(n,node); },
      setEnd:(n,i)=>{ assert.equal(n,node); end=i; },
      getClientRects:()=>boxes,
    }),
  };
  return {range,get end(){return end;}};
}
const normal = caret('猫',0,{left:50,top:60,width:0,height:22});
assert.equal(measure(normal.range).left,50);
assert.equal(normal.end,null,'normal carets must retain their geometry');
const vertical = caret('猫だ',0);
assert.equal(measure(vertical.range),glyph);
assert.equal(vertical.end,1);
assert.equal(vertical.range.startOffset,0,'original anchor must not mutate');
const astral = caret('猫𠮷だ',1);
assert.equal(measure(astral.range),glyph);
assert.equal(astral.end,3,'expand by a code point, not half a surrogate pair');
assert.equal(measure(caret('猫',1).range),null);
assert.equal(measure(caret('猫',0,empty,[empty]).range),null);
let start=0;
const spaced=caret('あ\n 𠮷',1);
spaced.range.cloneRange=()=>({
  setStart:(node,i)=>{start=i;},
  setEnd:(node,i)=>{if(start===3)assert.equal(i,5);},
  getClientRects:()=>start===3?[glyph]:[empty],
});
assert.equal(measure(spaced.range),glyph,'collapsed whitespace must not strand the anchor');
assert.equal(measure({...caret('猫',0).range,startContainer:{nodeType:1}}),null);
process.stdout.write('OK');
''';

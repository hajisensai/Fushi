import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import puppeteer from 'puppeteer-core';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);

// First run reader_headless_shell_dump_test.dart to emit the full production JS.
// Default: system Chrome. Set PLAYWRIGHT_MODULE to an installed playwright package
// to run WebKit (install its WebKit browser first); this is not iPhone device E2E.

const browser = process.env.PLAYWRIGHT_MODULE ? await require(process.env.PLAYWRIGHT_MODULE).webkit.launch() : await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const text = Array.from({length: 100}, (_, i) => `<p>\n  第${i}段。これは本文です。彼女は窓の外を眺めながら、遠い昔の出来事について静かに話し始めました。私はその言葉を聞きながら、今まで気付かなかった世界の広さを感じていました。</p>`).join('');
try {
  for (const continuous of [false, true]) for (const vertical of [false, true]) {
    const width = 390, height = 844;
    const mode = continuous ? 'continuous' : 'paginated';
    const engine = fs.readFileSync(path.join(os.tmpdir(), `fushi_full_engine_${mode}.js`), 'utf8');
    const css = `html,body{margin:0;padding:0} ${continuous ? '' : 'html{overflow:hidden}'} body{font-size:22px;line-height:1.8;writing-mode:${vertical ? 'vertical-rl' : 'horizontal-tb'};${continuous ? '' : `width:${width}px;height:${height}px;box-sizing:border-box;column-width:${vertical ? height : width}px;column-gap:0;column-fill:auto;overflow:hidden;`}}`;
    const config = {
      vnMode:false,continuousMode:continuous,initialFragment:null,initialCharOffset:-1,initialCharOffsetEnd:-1,initialProgress:0,
      dartPageWidth:width,dartPageHeight:height,chromeTopInset:0,chromeBottomInset:0,
      marginTop:0,marginBottom:0,marginLeft:0,marginRight:0,sentenceAudioCues:null,
      caretColor:'#ff0000',caretInsetTop:0,caretInsetBottom:0,furiganaMode:'always',
    };
    async function open(anchor) {
      const page = await browser.newPage();
      if (page.setViewport) await page.setViewport({width,height}); else await page.setViewportSize({width,height});
      page.on('pageerror', e => console.log('ERROR', e.message));
      await page.setContent(`<html><head><meta name="viewport" content="width=device-width"><style>${css}</style></head><body>${text}</body></html>`);
      await page.evaluate(() => { window.__completions = 0; window.flutter_inappwebview = {callHandler(name) { if(name === 'onRestoreComplete') window.__completions++; return Promise.resolve(); }}; });
      await page.evaluate(engine);
      await page.evaluate(c => window.__fushiEngine.install(c), {...config,...anchor});
      await page.waitForFunction(() => window.__completions > 0, {timeout:5000});
      await new Promise(r => setTimeout(r,150));
      return page;
    }
    const page = await open({});
    for (let i=0; i<4; i++) {
      await page.evaluate(() => window.fushiReader.paginate('forward'));
      await new Promise(r => setTimeout(r,100));
    }
    const saved = await page.evaluate(() => ({detail:window.fushiProgressDetails(), progress:window.fushiReader.calculateProgress()}));
    const offset = Number(saved.detail.split(',')[2]);
    assert(offset > 0, `${mode}/${vertical}: fixture did not leave chapter start`);
    const reopened = await open({initialCharOffset:offset,initialProgress:saved.progress});
    const restored = await reopened.evaluate(() => ({detail:window.fushiProgressDetails(), scroll:[document.body.scrollLeft,document.body.scrollTop,window.scrollX,window.scrollY]}));
        const geometry = await reopened.evaluate(offset => {
      const r=window.fushiReader; const w=r.createWalker(); let node, n=0;
      while(node=w.nextNode()) { const size=r.countChars(node.textContent); if(n+size>offset) break; n+=size; }
      if(!node) return null;
      let i=0,k=0; const t=node.textContent;
      while(i<t.length && k<offset-n) {if(window.fushiStudyUnits.isUnitEnd(t,i))k++; i+=t.codePointAt(i)>65535?2:1;}
      const range=document.createRange();range.setStart(node,i);range.collapse(true);
      const collapsed=range.getBoundingClientRect().toJSON();
      range.setEnd(node,Math.min(t.length,i+(t.codePointAt(i)>65535?2:1)));
      return {n,i,collapsed,expanded:range.getBoundingClientRect().toJSON(), text:t.slice(i,i+20)};
    },offset);
    console.log(JSON.stringify({mode,vertical,saved,offset,restored,geometry}));
    const restoredOffset = Number(restored.detail.split(',')[2]);
    assert(restoredOffset > 0, `${mode}/${vertical}: restore reset to chapter start`);
    if (vertical) {
      assert.equal(restoredOffset, offset, `${mode}: vertical anchor must survive reopen`);
    }
    await page.close(); await reopened.close();
  }
} finally { await browser.close(); }

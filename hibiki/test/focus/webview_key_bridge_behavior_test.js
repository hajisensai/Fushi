// 行为 harness：真执行 webViewKeyBridgeScript / dictionaryPopupInputBridgeScript
// 生成的 JS，喂合成事件，断言到底转发了什么。由同名 .dart 测试生成脚本并调起
// （`node <this> <payload.json>`）。源码扫描守卫只能证明字符串里有某几个片段，
// 证明不了「Shift+Space 会不会被误吞」「改键后新键生不生效」这类真正会咬人的问题。
//
// payload.json 形如 { "<caseName>": "<生成的 JS 源码>" , ... }。

import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const payloadPath = process.argv[2];
assert.ok(payloadPath, 'usage: node webview_key_bridge_behavior_test.js <payload.json>');
const scripts = JSON.parse(readFileSync(payloadPath, 'utf8'));

// ---- 最小 DOM：只实现桥脚本真正碰到的 API --------------------------------
function makeEnv() {
  const listeners = Object.create(null);
  const calls = [];
  const sandbox = {
    document: {
      addEventListener(type, fn) {
        (listeners[type] ||= []).push(fn);
      },
    },
  };
  sandbox.window = sandbox;
  sandbox.window.flutter_inappwebview = {
    callHandler(name, arg) {
      calls.push([name, arg]);
    },
  };
  return { sandbox, listeners, calls };
}

function run(env, src) {
  runInNewContext(src, env.sandbox);
}

function dispatch(env, type, event) {
  const ev = {
    preventDefault() {
      ev.defaultPrevented = true;
    },
    stopImmediatePropagation() {
      ev.propagationStopped = true;
    },
    defaultPrevented: false,
    propagationStopped: false,
    ...event,
  };
  for (const fn of env.listeners[type] || []) fn(ev);
  return ev;
}

function key(over) {
  return {
    key: 'Escape',
    code: 'Escape',
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    metaKey: false,
    repeat: false,
    isComposing: false,
    target: null,
    ...over,
  };
}

// ---- 1. 弹窗桥：默认 Escape + 鼠标后退键 ---------------------------------
{
  const env = makeEnv();
  run(env, scripts.escapeAndMouseBack);

  const esc = dispatch(env, 'keydown', key());
  assert.deepStrictEqual(env.calls, [['hostInputToken', 'Escape']],
    'Escape 必须交回宿主——这正是「关闭词典快捷键在弹窗持焦时没反应」的修复点');
  assert.ok(esc.defaultPrevented, '命中必须 preventDefault');
  assert.ok(esc.propagationStopped,
    '已交给宿主的键不能再让 popup.js 自己的监听二次响应');

  env.calls.length = 0;
  dispatch(env, 'mousedown', { button: 3 });
  assert.deepStrictEqual(env.calls, [['hostInputToken', 'Mouse3']],
    '鼠标侧键必须交回宿主——弹窗表面此前完全没有非左键通道(BUG-1071 已知边界)');

  env.calls.length = 0;
  dispatch(env, 'mousedown', { button: 0 });
  dispatch(env, 'mousedown', { button: 1 });
  assert.deepStrictEqual(env.calls, [],
    '左键(选词)与未绑定的中键必须原样留给弹窗，别抢走查词/滚动');

  // 侧键的默认副作用（浏览器历史后退）必须压掉，否则弹窗内容会被导航走。
  const aux = dispatch(env, 'auxclick', { button: 3 });
  assert.ok(aux.defaultPrevented, '命中的侧键要压掉 auxclick 默认导航');
  const auxOther = dispatch(env, 'auxclick', { button: 1 });
  assert.ok(!auxOther.defaultPrevented, '未绑定按钮不得干预页面');
}

// ---- 2. 长按不重复触发 ---------------------------------------------------
{
  const env = makeEnv();
  run(env, scripts.escapeAndMouseBack);
  dispatch(env, 'keydown', key({ repeat: true }));
  assert.deepStrictEqual(env.calls, [],
    '按住关词典键不该逐帧关掉弹窗栈的每一层');
}

// ---- 3. 裸 token 表不吞组合键（旧版靠独立分支放行，新版是不命中的自然结果）--
{
  const env = makeEnv();
  run(env, scripts.escapeAndMouseBack);
  dispatch(env, 'keydown', key({ shiftKey: true }));
  dispatch(env, 'keydown', key({ ctrlKey: true }));
  assert.deepStrictEqual(env.calls, [],
    '表里只有裸 Escape 时，Shift/Ctrl+Escape 必须放行给弹窗');
}

// ---- 4. 组合键 token 真能拦到（旧桥做不到：修饰键一律放行）---------------
{
  const env = makeEnv();
  run(env, scripts.ctrlKeyD);

  dispatch(env, 'keydown', key({ key: 'd', code: 'KeyD', ctrlKey: true }));
  assert.deepStrictEqual(env.calls, [['hostInputToken', 'Ctrl+KeyD']],
    '用户把关闭词典改绑成 Ctrl+D 时，弹窗持焦也必须能关');

  env.calls.length = 0;
  dispatch(env, 'keydown', key({ key: 'd', code: 'KeyD' }));
  assert.deepStrictEqual(env.calls, [], '裸 D 不在表里，不得误触');
}

// ---- 5. code 与 key 双通道（注册表 token 用 DOM code 命名）---------------
{
  const env = makeEnv();
  run(env, scripts.ctrlKeyD);
  // 日文/AZERTY 等布局下 e.key 可能不是 'd'，但 e.code 恒为 'KeyD'。
  dispatch(env, 'keydown', key({ key: 'ろ', code: 'KeyD', ctrlKey: true }));
  assert.deepStrictEqual(env.calls, [['hostInputToken', 'Ctrl+KeyD']],
    'token 必须能按 e.code 命中，否则换输入布局就失效');
}

// ---- 6. 键表热更新：改键立刻生效，listener 不叠加 -------------------------
{
  const env = makeEnv();
  run(env, scripts.escapeAndMouseBack);
  run(env, scripts.ctrlKeyD); // 用户在设置里改了键 → 宿主重新注入

  const keydownCount = (env.listeners.keydown || []).length;
  assert.strictEqual(keydownCount, 1,
    '重复注入只能更新键表，listener 必须只装一次（否则一次按键回传多次）');

  dispatch(env, 'keydown', key());
  assert.deepStrictEqual(env.calls, [],
    '旧键(Escape)改绑后必须失效——旧桥把键表冻结在首次注入的闭包里，改键不跟随');

  env.calls.length = 0;
  dispatch(env, 'keydown', key({ key: 'd', code: 'KeyD', ctrlKey: true }));
  assert.deepStrictEqual(env.calls, [['hostInputToken', 'Ctrl+KeyD']],
    '新键必须立刻生效');

  env.calls.length = 0;
  dispatch(env, 'mousedown', { button: 3 });
  assert.deepStrictEqual(env.calls, [],
    '鼠标表同样要跟着更新，不能留着上一份绑定');
}

// ---- 7. 输入框 / IME 放行 ------------------------------------------------
{
  const env = makeEnv();
  run(env, scripts.escapeAndMouseBack);
  dispatch(env, 'keydown', key({ target: { tagName: 'INPUT' } }));
  dispatch(env, 'keydown', key({ target: { tagName: 'TEXTAREA' } }));
  dispatch(env, 'keydown', key({ target: { isContentEditable: true } }));
  dispatch(env, 'keydown', key({ isComposing: true }));
  assert.deepStrictEqual(env.calls, [],
    '输入框内与 IME 组字中必须放行，否则打字打不出来');
}

// ---- 8. 空表：桥装着但不拦任何输入（基类默认 / 用户清空绑定）-------------
{
  const env = makeEnv();
  run(env, scripts.emptySpec);
  dispatch(env, 'keydown', key());
  dispatch(env, 'mousedown', { button: 3 });
  assert.deepStrictEqual(env.calls, [], '空表不得拦截任何输入');
}

// ---- 9. 老宿主（阅读器空格桥）语义零变化 ---------------------------------
{
  const env = makeEnv();
  run(env, scripts.legacySpace);

  dispatch(env, 'keydown', key({ key: ' ', code: 'Space' }));
  assert.deepStrictEqual(env.calls, [['onSpaceKey', ' ']],
    '裸空格仍按 e.key 命中并回传原 token');

  env.calls.length = 0;
  dispatch(env, 'keydown', key({ key: ' ', code: 'Space', shiftKey: true }));
  dispatch(env, 'keydown', key({ key: ' ', code: 'Space', ctrlKey: true }));
  assert.deepStrictEqual(env.calls, [],
    'Shift+Space / Ctrl+Space 必须仍然放行（阅读器把它们另绑了翻页/播放）');

  env.calls.length = 0;
  const repeated = dispatch(env, 'keydown', key({ key: ' ', code: 'Space', repeat: true }));
  assert.deepStrictEqual(env.calls, [['onSpaceKey', ' ']],
    '阅读器默认保留长按连发');
  assert.ok(!repeated.propagationStopped,
    '未开 stopPropagation 的宿主不得独占事件');

  assert.strictEqual((env.listeners.mousedown || []).length, 0,
    '只用键盘的宿主不得生成鼠标监听（零行为变化）');
}

console.log('all assertions passed');

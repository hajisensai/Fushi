// gap-readerjs1-2 behavior test: the reader engine's init / initial-restore chain
// has a failure exit.
//
// Before the fix the chain `Promise.all(imagePromises).then(function() { ... })`
// had no catch: a synchronous throw in buildNodeOffsets, in the audiobook cue
// application or in the restore entry turned it into an unhandled rejected
// promise, onRestoreComplete never arrived and Dart sat behind the loading mask
// until its 8 s content-ready fallback. A throw from initialize() itself was
// contained by the boot wrapper (BUG-1017) but equally never reported.
//
// This runner executes the production text of the three shells (paginated /
// continuous / VN, piped as JSON on stdin by the Dart driver) against fakes and
// asserts:
//   A. a throwing applySentenceAudioCues is isolated: console.error reports it,
//      the restore still runs and onRestoreComplete is sent;
//   B. a throwing restore entry / buildNodeOffsets sends onRestoreFailed with the
//      document's navigation generation;
//   C. a restore that already reported success and then throws does not send a
//      second (failure) receipt;
//   D. the boot wrapper reports a throwing initialize() as onRestoreFailed;
//   E. the VN shell follows the same receipt contract (boot failure -> failure
//      receipt, success first -> no failure receipt).
//
// BUG-4906 follow-up (asynchronous throws): every restore entry is an async
// function and hands its settle + receipt to a deferred callback, so a throw
// after the first `await` or inside that callback never reached the chain's
// catch and Dart again waited for the 8 s fallback:
//   F. a restore entry that rejects after an await sends onRestoreFailed
//      (paginated / continuous chain); in VN the rejection is caught and logged,
//      and only sends a failure receipt when initialize() has not already sent
//      the success receipt (in production it always has — see vnAsyncCase);
//   G. a throw inside the receipt-carrying deferred callback (paginated
//      `_settleAndNotify`, continuous chapter-start restore) sends onRestoreFailed,
//      and the same callback without a throw still sends only the success receipt.

const assert = require('node:assert');
const { readPayload, shellObjectLiteral, compileScript } = require('./reader_harness_support.js');

const scripts = readPayload();
const GENERATION = 7;

function cut(source, startNeedle, endNeedle, what, fromEnd) {
  const start = fromEnd ? source.lastIndexOf(startNeedle) : source.indexOf(startNeedle);
  assert.ok(start >= 0, what + ' start missing');
  const end = source.indexOf(endNeedle, start);
  assert.ok(end >= 0, what + ' end missing');
  return source.slice(start, end + endNeedle.length);
}

function makeEnv(extraC) {
  const calls = [];
  const errors = [];
  const window = {
    scrollX: 0,
    CSS: {},
    Highlight: function() {},
    flutter_inappwebview: { callHandler: (...args) => calls.push(args) },
  };
  const console = { error: (...args) => errors.push(args.map(String).join(' ')), log: () => {} };
  window.console = console;
  const document = {
    documentElement: { style: { setProperty: () => {} } },
    scrollingElement: null,
    readyState: 'complete',
    fonts: { ready: Promise.resolve() },
  };
  // Deferred callbacks the shell schedules; a case runs them explicitly.
  const timers = [];
  const C = Object.assign({
    perfTraceEnabled: false,
    navigationGeneration: GENERATION,
    sentenceAudioCues: [{ id: 'c1' }],
    initialFragment: null,
    initialCharOffset: -1,
    initialCharOffsetEnd: -1,
    initialProgress: 0.3,
    vnRevealSpeed: 0,
    vnScreenMode: 'sentence',
    vnSentencesPerScreen: 1,
    vnPreserveDialogue: false,
  }, extraC || {});
  const fakeSetTimeout = (fn) => {
    timers.push(fn);
    return timers.length;
  };
  return { calls, errors, window, console, document, C, timers, setTimeout: fakeSetTimeout };
}

function instantiate(shellSource, env) {
  const factory = compileScript(
    ['window', 'document', 'C', 'console', 'CSS', 'Highlight', 'setTimeout'],
    'window.fushiReader = ' + shellObjectLiteral(shellSource) + '; return window.fushiReader;',
    'shell-object.js'
  );
  const reader = factory(env.window, env.document, env.C, env.console, env.window.CSS, env.window.Highlight, env.setTimeout);
  reader.warmPaginationMetrics = () => {};
  return reader;
}

function handlerNames(env) {
  return env.calls.map((c) => c[0]);
}

async function runChain(shellSource, env) {
  const chain = cut(shellSource, 'Promise.all(imagePromises).then(function() {', '\n  });', 'restore chain');
  const run = compileScript(
    ['window', 'C', 'imagePromises', 'console'],
    'return ' + chain,
    'restore-chain.js',
  );
  try {
    await run(env.window, env.C, [], env.console);
  } catch (e) {
    // An uncaught chain rejection is exactly the pre-fix bug; the receipt
    // assertions below report it.
  }
}

async function shellCases(name, shellSource) {
  // A. cue application throws -> isolated, restore still lands.
  {
    const env = makeEnv();
    const reader = instantiate(shellSource, env);
    const restored = [];
    reader.buildNodeOffsets = () => {};
    reader.applySentenceAudioCues = () => { throw new Error('cue boom'); };
    reader.restoreProgress = (p) => { restored.push(p); reader.notifyRestoreComplete(); };
    await runChain(shellSource, env);
    assert.deepStrictEqual(restored, [0.3], name + ' A: restore must still run after a cue failure');
    assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], name + ' A: success receipt only');
    assert.ok(env.errors.some((e) => e.includes('applySentenceAudioCues failed')), name + ' A: cue failure reported on console');
  }
  // B1. restore entry throws -> failure receipt with generation.
  {
    const env = makeEnv();
    const reader = instantiate(shellSource, env);
    reader.buildNodeOffsets = () => {};
    reader.applySentenceAudioCues = () => {};
    reader.restoreProgress = () => { throw new Error('restore boom'); };
    await runChain(shellSource, env);
    assert.strictEqual(env.calls.length, 1, name + ' B1: exactly one receipt, got ' + JSON.stringify(env.calls));
    assert.strictEqual(env.calls[0][0], 'onRestoreFailed', name + ' B1: failure receipt');
    assert.strictEqual(env.calls[0][1], 'restore boom', name + ' B1: reason forwarded');
    assert.strictEqual(env.calls[0][2], GENERATION, name + ' B1: generation forwarded');
  }
  // B2. buildNodeOffsets throws -> failure receipt.
  {
    const env = makeEnv({ sentenceAudioCues: null });
    const reader = instantiate(shellSource, env);
    reader.buildNodeOffsets = () => { throw new Error('offsets boom'); };
    reader.restoreProgress = () => reader.notifyRestoreComplete();
    await runChain(shellSource, env);
    assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], name + ' B2: failure receipt');
    assert.strictEqual(env.calls[0][2], GENERATION, name + ' B2: generation forwarded');
  }
  // C. success already reported, then a throw -> no second receipt.
  {
    const env = makeEnv({ sentenceAudioCues: null });
    const reader = instantiate(shellSource, env);
    reader.buildNodeOffsets = () => {};
    reader.restoreProgress = () => { reader.notifyRestoreComplete(); throw new Error('late boom'); };
    await runChain(shellSource, env);
    assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], name + ' C: no failure after success');
  }
  // F. restore entry rejects after an await -> failure receipt (the chain must
  // receive the entry's promise, not a value it already resolved past).
  {
    const env = makeEnv({ sentenceAudioCues: null });
    const reader = instantiate(shellSource, env);
    reader.buildNodeOffsets = () => {};
    reader.restoreProgress = async () => {
      await null;
      throw new Error('async restore boom');
    };
    await runChain(shellSource, env);
    assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], name + ' F: async rejection must send a failure receipt');
    assert.strictEqual(env.calls[0][1], 'async restore boom', name + ' F: reason forwarded');
    assert.strictEqual(env.calls[0][2], GENERATION, name + ' F: generation forwarded');
  }
}

/// Runs the next deferred callback; returns what escaped from it (null if nothing).
function runNextTimer(env) {
  const callback = env.timers.shift();
  assert.ok(callback, 'a deferred callback must have been scheduled');
  try {
    callback();
    return null;
  } catch (escaped) {
    return escaped;
  }
}

// G (paginated). The settle callback re-anchors when the position moved, then
// sends the receipt; a throw there must turn into the failure receipt.
function pagedSettleCases() {
  for (const throws of [true, false]) {
    const env = makeEnv({ sentenceAudioCues: null });
    const reader = instantiate(scripts.paged, env);
    let position = 0;
    reader.getScrollContext = () => ({});
    reader.getPagePosition = () => position;
    reader.registerSnapScroll = () => {};
    reader.reapplyImageLateAnchor = () => {
      if (throws) throw new Error('settle boom');
    };
    reader._settleAndNotify();
    position = 120;
    const escaped = runNextTimer(env);
    assert.strictEqual(escaped, null, 'paged G: the settle callback must not let the throw escape unreported');
    if (throws) {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], 'paged G: settle throw must send a failure receipt');
      assert.strictEqual(env.calls[0][1], 'settle boom', 'paged G: reason forwarded');
      assert.strictEqual(env.calls[0][2], GENERATION, 'paged G: generation forwarded');
    } else {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], 'paged G: a clean settle sends only the success receipt');
    }
  }
}

// G (continuous). Chapter-start restore re-applies the start position in its
// deferred callback before the receipt.
async function continuousSettleCases() {
  for (const throws of [true, false]) {
    const env = makeEnv({ sentenceAudioCues: null });
    const reader = instantiate(scripts.continuous, env);
    let starts = 0;
    reader.scrollToChapterStart = () => {
      starts += 1;
      if (throws && starts === 2) throw new Error('chapter start boom');
    };
    await reader.restoreProgress(0);
    const escaped = runNextTimer(env);
    assert.strictEqual(starts, 2, 'continuous G: the deferred callback re-applies the chapter start');
    assert.strictEqual(escaped, null, 'continuous G: the deferred callback must not let the throw escape unreported');
    if (throws) {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], 'continuous G: callback throw must send a failure receipt');
      assert.strictEqual(env.calls[0][1], 'chapter start boom', 'continuous G: reason forwarded');
    } else {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], 'continuous G: a clean restore sends only the success receipt');
    }
  }
}

function bootCase(name, shellSource) {
  const env = makeEnv();
  const reader = instantiate(shellSource, env);
  reader.initialize = () => { throw new Error('init boom'); };
  const boot = cut(shellSource, 'function _fushiBootInitialize() {', '\n}\n', 'boot wrapper');
  compileScript(
    ['window', 'console'],
    boot + '\n_fushiBootInitialize();',
    'boot.js',
  )(env.window, env.console);
  assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], name + ' D: boot failure must send a failure receipt');
  assert.strictEqual(env.calls[0][2], GENERATION, name + ' D: generation forwarded');
  assert.ok(env.errors.some((e) => e.includes('boot initialize failed')), name + ' D: boot failure still logged');
}

function vnCases(vnSource) {
  {
    const env = makeEnv();
    const reader = instantiate(vnSource, env);
    reader.initialize = () => { throw new Error('vn init boom'); };
    const boot = cut(vnSource, "if (document.readyState === 'complete') {", '\n}\n', 'VN boot block', true);
    compileScript(
      ['window', 'document', 'C', 'console'],
      boot,
      'vn-boot.js',
    )(env.window, env.document, env.C, env.console);
    assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], 'VN E: boot failure must send a failure receipt');
    assert.strictEqual(env.calls[0][2], GENERATION, 'VN E: generation forwarded');
  }
  {
    const env = makeEnv();
    const reader = instantiate(vnSource, env);
    reader.notifyRestoreComplete();
    reader.notifyRestoreFailed(new Error('after success'));
    assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], 'VN E: no failure receipt after success');
  }
}

// F (VN). The boot's try/catch only sees synchronous throws; an entry that
// rejects after awaiting readyPromise must be caught and logged, never left as an
// unhandled rejection.
//   F1 is the production order: initialize()'s readyPromise sends
//      onRestoreComplete (success and fail-open branches alike) before the entry
//      resumes past `await ensureReady()`, so the later rejection is logged and
//      the one-outcome-per-document contract keeps it from adding a failure receipt.
//   F2 pins the receipt contract when no receipt went out yet.
async function vnAsyncCase(vnSource) {
  for (const receiptFirst of [true, false]) {
    const label = receiptFirst ? 'VN F1' : 'VN F2';
    const env = makeEnv();
    const reader = instantiate(vnSource, env);
    reader.initialize = () => {
      if (receiptFirst) reader.notifyRestoreComplete();
    };
    reader.restoreProgress = async () => {
      await null;
      throw new Error('vn async boom');
    };
    const unhandled = [];
    const onUnhandled = (reason) => unhandled.push(reason);
    process.on('unhandledRejection', onUnhandled);
    try {
      const boot = cut(vnSource, "if (document.readyState === 'complete') {", '\n}\n', 'VN boot block', true);
      compileScript(
        ['window', 'document', 'C', 'console'],
        boot,
        'vn-boot.js',
      )(env.window, env.document, env.C, env.console);
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));
    } finally {
      process.off('unhandledRejection', onUnhandled);
    }
    assert.deepStrictEqual(unhandled, [], label + ': the async rejection must not be left unhandled');
    assert.ok(
      env.errors.some((e) => e.includes('initial restore failed') && e.includes('vn async boom')),
      label + ': the async rejection must be logged, got ' + JSON.stringify(env.errors),
    );
    if (receiptFirst) {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreComplete'], label + ': no failure receipt after the success receipt');
    } else {
      assert.deepStrictEqual(handlerNames(env), ['onRestoreFailed'], label + ': async rejection must send a failure receipt');
      assert.strictEqual(env.calls[0][1], 'vn async boom', label + ': reason forwarded');
      assert.strictEqual(env.calls[0][2], GENERATION, label + ': generation forwarded');
    }
  }
}

async function main() {
  await shellCases('paged', scripts.paged);
  await shellCases('continuous', scripts.continuous);
  bootCase('paged', scripts.paged);
  bootCase('continuous', scripts.continuous);
  vnCases(scripts.vn);
  pagedSettleCases();
  await continuousSettleCases();
  await vnAsyncCase(scripts.vn);
  console.log('all assertions passed');
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});

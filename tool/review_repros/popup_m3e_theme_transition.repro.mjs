// HBK-AUDIT-015: standalone reproduction outside the default test/ discovery tree.
// Run: node --test tool/review_repros/popup_m3e_theme_transition.repro.mjs
// Real production tone functions; minimal DOM/style/RAF boundary mock, no browser.
// Desired hot-theme contracts are expected to fail until the production fix lands.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../../fushi/assets/popup/popup.js', import.meta.url), 'utf8');
const start = source.indexOf('var __fushiM3eToneRoots = null;');
const end = source.indexOf('// BUG-1898:', start);
assert.ok(start >= 0 && end > start, 'production tone-function extraction anchors');
const toneSource = source.slice(start, end);

function fixture(initialTheme) {
  const properties = new Map([
    ['background-color', { value: 'rgb(255, 255, 255)', priority: '' }],
    ['color', { value: 'rgb(0, 0, 0)', priority: '' }],
  ]);
  const card = {
    tagName: 'DIV', isConnected: true,
    matches: (selector) => selector === '.glossary-group > div[data-dictionary]',
    querySelectorAll: () => [],
    style: {
      setProperty: (key, value, priority) => properties.set(key, { value, priority }),
      getPropertyValue: (key) => properties.get(key)?.value ?? '',
      getPropertyPriority: (key) => properties.get(key)?.priority ?? '',
    },
  };
  const attributes = new Map([['data-theme', initialTheme]]);
  const classes = new Set(['fushi-m3e']);
  const html = {
    classList: { contains: (name) => classes.has(name) },
    getAttribute: (name) => attributes.get(name),
    setAttribute: (name, value) => attributes.set(name, value),
  };
  let frames = [];
  const scope = {
    console,
    document: { documentElement: html },
    __fushiContainer: () => null,
    requestAnimationFrame: (callback) => (frames.push(callback), frames.length),
    getComputedStyle: (node) => ({
      backgroundColor: node.style.getPropertyValue('background-color'),
      color: node.style.getPropertyValue('color'),
    }),
  };
  runInNewContext(toneSource, scope);
  function flush() {
    const pending = frames;
    frames = [];
    pending.forEach((callback) => callback());
  }
  function postProcess() {
    scope.__fushiScheduleM3eDictTone(card);
    flush();
  }
  // dictionary_popup_webview.dart:1463..1478 sends themeVarsJs only.
  // popup_settings_injection.dart:153..159 updates class + data-theme;
  // CSS variables do not override dictionary inline !important properties.
  function setTheme(theme) {
    html.setAttribute('data-theme', theme);
    flush();
  }
  return { card, postProcess, setTheme };
}

test('control: initial dark rendering tones a white dictionary block', () => {
  const { card, postProcess } = fixture('dark');
  postProcess();
  assert.equal(card.style.getPropertyValue('background-color'), 'hsl(0, 0%, 22%)');
  assert.equal(card.style.getPropertyValue('color'), 'hsl(0, 0%, 82%)');
  assert.equal(card.style.getPropertyPriority('background-color'), 'important');
});

test('control: initial light rendering preserves dictionary colors', () => {
  const { card, postProcess } = fixture('light');
  postProcess();
  assert.equal(card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
});

test('HBK-AUDIT-015: dark to light restores original dictionary colors on existing DOM', () => {
  const { card, postProcess, setTheme } = fixture('dark');
  postProcess();
  setTheme('light');
  assert.equal(card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
  assert.equal(card.style.getPropertyValue('color'), 'rgb(0, 0, 0)');
});

test('HBK-AUDIT-015: light to dark tones already-rendered dictionary colors', () => {
  const { card, postProcess, setTheme } = fixture('light');
  postProcess();
  setTheme('dark');
  assert.equal(card.style.getPropertyValue('background-color'), 'hsl(0, 0%, 22%)');
});

test('HBK-AUDIT-015: invoking the existing scheduler again in light mode cannot restore colors', () => {
  const { card, postProcess, setTheme } = fixture('dark');
  postProcess();
  setTheme('light');
  postProcess();
  assert.equal(card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
});

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const popupCss = fs.readFileSync(path.join(ROOT, 'vendor', 'popup.css'), 'utf8');
const popupJs = fs.readFileSync(path.join(ROOT, 'vendor', 'popup.js'), 'utf8');

test('BUG-1895: static mine plus matches adjacent SVG height', () => {
  assert.match(
    popupCss,
    /\.mine-button:not\(\.duplicate\)\s*\{\s*font-size:\s*30px;\s*\}/,
  );
});

test('BUG-1895: mine button reuses clickable action layout', () => {
  assert.match(
    popupJs,
    /className:\s*'inline-action-button mine-button'/,
  );
});

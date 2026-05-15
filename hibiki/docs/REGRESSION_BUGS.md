# Regression Bugs

## HBK-REG-001 Dictionary HTML Image Media Path

- status: fixed
- first reproduced: 2026-05-15
- affected area: dictionary popup / structured dictionary WebView media
- root cause: HTML definition images were not rewritten through the dictionary media scheme, and imported media paths could keep Windows-style `\` separators while HTML requests use `/`.
- reproduction: import `.codex-test/fixtures/html-image-yomitan.zip` via DocumentsUI, search `htmlimg`, open the result.
- evidence:
  - before fix screenshot: `.codex-test/dict-image-fix-htmlimg-result-clean-valid.png`
  - verified screenshot: `.codex-test/dict-image-fix-htmlimg-verified.png`
  - verified UI XML: `.codex-test/dict-image-fix-htmlimg-verified.xml`
  - verified logcat: `.codex-test/dict-image-fix-htmlimg-reload-logcat.txt`
- verification: CDP reported the dictionary image as `naturalWidth=120` and `naturalHeight=60`; screenshot pixel check found the test SVG colors.

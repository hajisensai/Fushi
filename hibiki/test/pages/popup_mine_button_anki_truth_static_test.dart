import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-186 (TODO-084/087): the popup mine button's "已制卡 ✓ / 可制卡 +" state is
// DETECTED AT LOOKUP TIME and reflects Anki's REAL card existence.
//
// PRIMARY MECHANISM: when the popup renders a word (createEntryHeader runs as
// part of renderPopup, which rebuilds the DOM on every lookup), the initial
// `duplicateCheck` queries Anki live (AnkiConnect findNotes / AnkiDroid
// findDuplicateNotes — see packages/hibiki_anki/test/ankiconnect_service_test
// .dart's "isDuplicate" group) and sets a real `data-mined` state via
// setMineState: card in Anki -> 已制卡 ✓, card absent -> 可制卡 +. The ✓ is NOT
// decorative; data-mined is the source of truth for what a click does.
//
// TODO-084 (re-look-up the word after deleting its card in Anki) is satisfied
// for free: a fresh lookup re-renders -> re-runs lookup-time detection ->
// data-mined cleared -> mineable again.
//
// TODO-087 edge case (same popup, card deleted in Anki WITHOUT re-looking up):
// a click on a 已制卡 ✓ button re-verifies via duplicateCheck BEFORE mining, so
// a stale ✓ whose card was deleted is re-mined; an existing card (dupes off) is
// not duplicated. This is a fallback, not the primary path.
//
// The old bug: the button started `disabled: true` and once a card existed it
// set `disabled = wasAdded && !allowDupes` — a permanent lock that only a
// re-render could clear. We regression-lock the fix here.
//
// Behavior coverage lives in
// hibiki/test/utils/misc/popup_asset_behavior_test.js
// (lookup-time detection / re-lookup re-mine / edge-case re-verify-on-click).
void main() {
  late String source;
  late String mineButtonBlock;

  setUpAll(() {
    source = File('assets/popup/popup.js').readAsStringSync();
    final int start = source.indexOf("className: 'mine-button'");
    expect(start, greaterThanOrEqualTo(0),
        reason: 'mine button element not found');
    // Bound the block at the header appendChild that follows the initial
    // duplicateCheck `.then(...)`, covering setMineState wiring + onclick + the
    // lookup-time detection call.
    final int end =
        source.indexOf('header.appendChild(buttonsContainer)', start);
    expect(end, greaterThan(start));
    mineButtonBlock = source.substring(start, end);
  });

  test('mine button is never permanently disabled by a duplicate', () {
    // The old permanent-lock patterns must be gone.
    expect(mineButtonBlock.contains('disabled: true'), isFalse,
        reason: 'mine button must not start permanently disabled');
    expect(mineButtonBlock.contains('disabled = wasAdded'), isFalse,
        reason: 'a successful mine must not lock the button');
    expect(mineButtonBlock.contains('disabled = isDuplicate'), isFalse,
        reason: 'an existing card must not lock the button');
    expect(RegExp(r'disabled\s*=\s*[^;]*allowDupes').hasMatch(mineButtonBlock),
        isFalse,
        reason: 'duplicate state must never gate the disabled flag');
  });

  test('button state is detected at lookup time via the initial duplicateCheck',
      () {
    // The whole block (which ends at header.appendChild) must contain the
    // lookup-time detection: a trailing duplicateCheck whose result drives
    // setMineState, so the rendered button reflects Anki's real card existence.
    final int initIdx = mineButtonBlock.lastIndexOf(
        "callHandler('duplicateCheck', { expression, reading }).then");
    expect(initIdx, greaterThanOrEqualTo(0),
        reason: 'a lookup-time duplicateCheck must run when the popup renders');
    final String initBody = mineButtonBlock.substring(initIdx);
    expect(initBody.contains('setMineState('), isTrue,
        reason: 'the lookup-time detection must set the real button state, not '
            'a purely-visual indicator');
  });

  test('a meaningful data-mined state is the source of truth, not decoration',
      () {
    // setMineState records data-mined; onclick branches on data-mined to decide
    // whether the click is the edge-case re-verify path or a normal mine.
    expect(mineButtonBlock.contains('dataset.mined'), isTrue,
        reason: 'the button must carry a real data-mined state set at lookup '
            'time, not just a ✓ glyph');
    final int onclickIdx = mineButtonBlock.indexOf('onclick: async () => {');
    expect(onclickIdx, greaterThanOrEqualTo(0));
    final String onclickBody = mineButtonBlock.substring(onclickIdx);
    expect(onclickBody.contains("dataset.mined === '1'"), isTrue,
        reason: 'onclick must read the lookup-time-detected mined state');
  });

  test('TODO-087 edge case: clicking a mined ✓ re-verifies Anki before mining',
      () {
    final int onclickIdx = mineButtonBlock.indexOf('onclick: async () => {');
    expect(onclickIdx, greaterThanOrEqualTo(0));
    final String onclickBody = mineButtonBlock.substring(onclickIdx);
    // The mined branch re-queries Anki, and the duplicateCheck inside it runs
    // BEFORE mineEntry so a card deleted in Anki is re-mined.
    final int minedBranchIdx = onclickBody.indexOf("dataset.mined === '1'");
    expect(minedBranchIdx, greaterThanOrEqualTo(0));
    final int dupCheckIdx =
        onclickBody.indexOf("callHandler('duplicateCheck'", minedBranchIdx);
    final int mineIdx = onclickBody.indexOf('mineEntry(', minedBranchIdx);
    expect(dupCheckIdx, greaterThan(minedBranchIdx),
        reason: 'the mined branch must re-query Anki');
    expect(mineIdx, greaterThan(dupCheckIdx),
        reason: 'duplicateCheck must run BEFORE mineEntry so a card deleted in '
            'Anki is re-mined');
  });

  test('the in-flight guard is always released', () {
    final int onclickIdx = mineButtonBlock.indexOf('onclick: async () => {');
    final String onclickBody = mineButtonBlock.substring(onclickIdx);
    expect(onclickBody.contains('finally {'), isTrue,
        reason: 'onclick must release its guard in a finally block');
    expect(onclickBody.contains('mineButton.disabled = false'), isTrue,
        reason: 'finally must always re-enable the button');
  });
}

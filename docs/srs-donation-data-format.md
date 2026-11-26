# Fushi review-history donation: data format

This document is for the anki-rwkv maintainers who receive Fushi donation batches. It describes what is in each
file and how it differs from a native Anki export. Every statement here comes from the exporter source
(`packages/fushi_engine/lib/srs/apkg/srs_donation_export.dart` and `srs_apkg_export.dart`). Format version: **1**.

## 1. Batches

The Fushi maintainer sends one private link per batch, usually monthly:

```
https://rank.fushi.moe/d/srs-donations/<token>/                 JSON manifest
https://rank.fushi.moe/d/srs-donations/<token>/<donorId>.apkg   one donor's file
https://rank.fushi.moe/d/srs-donations/<token>/withdrawn.txt    withdrawn donor IDs, one per line
```

- The token is 32 random bytes. It is the only credential, so please don't forward the link. A link expires
  **30 days** after it is created; after that every URL under it returns 404.
- The manifest looks like this:
  `{"format":"fushi-srs-donation-batch","createdAt":ms,"expiresAt":ms,"files":[{"donorId","reviews","cards","bytes","updatedAt","url"}],"withdrawn":[donorId…],"withdrawnUrl"}`.
- A batch is a snapshot of **every current donation**, not only the ones that changed since the last batch. Each
  donor has exactly one file. When a donor re-uploads, the new file is a complete export that **replaces** the
  previous one under the same `donorId`. It is not an increment.
- `donorId` is 32 lowercase hex characters. It stays the same for a given Fushi profile on every device, and it
  matches `fushi_donation_meta.donor_id` inside the file.
- **Withdrawals**: `withdrawn` / `withdrawn.txt` list the donors who withdrew since the previous batch. Please
  delete all of their data and exclude it from future training. Fushi has already deleted the stored file. A
  donor who withdrew can donate again later. In that case they appear in `files` of a later batch, and that
  file is a new consent. If a file was withdrawn after the batch snapshot was taken, its URL returns 404.

## 2. File layout

Each file is a legacy Anki `.apkg`: a zip archive that contains two entries.

| Entry | Content |
|---|---|
| `collection.anki21` | SQLite, Anki schema 11 (`col.ver = 11`) |
| `media` | always `{}`: the file contains no media |

There is no `fushi-ext` entry and there are no other files. Anki can import the file as an ordinary package.
The collection also contains two extra tables, `fushi_revlog_origin` and `fushi_donation_meta`, described in
sections 4 and 5.

Scope: the file covers all decks of one Fushi profile. A note is included only if at least one of its cards has
at least one review log. Cards hidden in Fushi and deleted notes are left out. Unreviewed sibling cards of an
included note are still included as new cards, but they have no revlog rows.

## 3. Tables and columns

Legend: **real** = meaningful data; **derived** = computed by Fushi (see notes); **placeholder** = constant or
blank, so please ignore it.

### `revlog`

| Column | Status | Meaning |
|---|---|---|
| `id` | real | The answer time in epoch ms. For logs that were imported from Anki, this is the **original Anki revlog id**. If two exported rows would get the same ms value, the later one is shifted by +1 ms (ordered by time, then by Fushi log id). |
| `cid` | real | The card id (see the id note below). |
| `ease` | real | The rating, 1–4 (Again / Hard / Good / Easy). `type = 3` rows imported from Anki keep their original Anki rating as well, so a donation package has no `ease = 0` rows. |
| `ivl` | derived | The interval that Fushi's scheduler chose after this answer. A positive value is days. A negative value is seconds until the next learning or relearning step. `0` means no state (only on `type = 3` rows). |
| `lastIvl` | derived | The `ivl` of the **previous exported row for the same card**, or 0 for the card's first row. Fushi recomputes it, so it does not come from Anki. |
| `factor` | placeholder | Fushi does not use SM-2 ease. For native Fushi reviews this is always `2500` (or `0` if the card was still new after the answer). For logs imported from Anki it is the original Anki `factor`. Do not use it. |
| `time` | real | The answer duration in ms. The exporter does **not** cap it, but Fushi caps the value at **60 000 ms** when it records the review (see section 6.4). |
| `type` | real | The queue the card was in **before** the answer. It uses Anki's codes: 0 = learn (also used for a new card's first answer), 1 = review, 2 = relearn, 3 = filtered (only on rows imported from Anki). Rows of types 4 and 5 (manual and rescheduled) are never written. |
| `usn` | placeholder | `-1` |

Only Fushi logs of kind `review` are exported. These are left out:

- manual reschedules, "set due date", resets, and Anki revlog rows of types 4 and 5 (Anki rows of types 0–2 with ease 0 are also manual operations in Fushi, so they are left out too);
- import anchors and Fushi-internal events;
- reviews that the user undid.

### `cards`

| Column | Status | Meaning |
|---|---|---|
| `id`, `nid`, `did` | real | Stable ids (see the id note below). |
| `ord` | real | Template index (for cloze notes: cloze number − 1). |
| `type`, `queue`, `due`, `ivl`, `reps`, `lapses` | derived | The card's current Fushi state in Anki encoding: `type`/`queue` 0 = new, 1 = learning, 2 = review, 3 = relearning; `queue = -1` = suspended. For review cards, `due` counts days from `col.crt`. For (re)learning cards, `due` is epoch seconds. `ivl` is the scheduled interval in days. |
| `factor` | placeholder | Same meaning as `revlog.factor`. |
| `flags` | real | The user's card flag, 0–7. |
| `mod`, `usn`, `left`, `odue`, `odid`, `data` | placeholder | `data` is `''`: FSRS memory states (stability and difficulty) are **not** exported. |

### `notes`

| Column | Status | Meaning |
|---|---|---|
| `id` | real | A stable id. |
| `guid` | derived | The first 10 hex characters of `sha256(original guid)`. It is the same for the same note across re-uploads, but it is not the guid of any shared deck. |
| `mid` | real | The note-type id. |
| `flds` | redacted | Every field is `''` except the optional headword and reading fields (section 7). |
| `sfld`, `csum` | derived | Recomputed from the first field after redaction. |
| `tags` | placeholder | Always `''`. |
| `mod`, `usn`, `flags`, `data` | placeholder | |

### `col`

- `crt` is the start of the day before the earliest review-card due day. It is not the real collection creation
  time.
- `conf` holds `rollover`, `creationOffset`, `localOffset` (section 6.1), `schedVer: 2`, and `fsrs: true`.
- `models`:
  - Note-type names are `NoteType <n>`.
  - Field names are `Headword`, `Reading`, or `Field <n>`, where `n` is the field's position starting from 1.
  - Template names are `Card <i>`.
  - Template bodies are minimal placeholders that reference only the first field.
  - CSS and field descriptions are empty.
  - The number and order of templates and fields are unchanged, so `cards.ord` still works.
- `decks`:
  - Deck names are `Deck <n>` at every level, with hierarchy kept (for example `Deck 1::Deck 3`). The default deck
    is `Default`.
  - Each deck's `conf` points to its preset.
  - Numbering follows the sorted numeric id, so it is stable within one file. It is not stable across uploads.
- `dconf`: presets are named `Preset <n>`.
  - In Fushi, a deck either owns its scheduling settings or inherits them from an ancestor. The preset id is the
    numeric id of the deck that owns the settings. Decks that inherit share their owner's preset. The default deck
    is preset 1.
  - Real values in a preset: `new.delays` (learning steps in minutes), `lapse.delays` (relearning steps),
    `desiredRetention`, `rev.maxIvl`, and `fsrsParams6` (FSRS-6 parameters, when present).
  - `rwkvReviewEnabled: true` is present when the deck schedules with RWKV.
  - Other keys are Anki defaults (for example `maxTaken: 60`) and do not describe Fushi behaviour.

**Ids.** `cards.id`, `notes.id`, and non-default deck and preset ids are 53-bit hashes of Fushi's internal
UUIDs. They are stable across re-uploads from the same profile. They are **not** the original Anki ids, even for
content that was imported from Anki. Only `revlog.id` keeps the original Anki value.

## 4. `fushi_revlog_origin`

```sql
CREATE TABLE fushi_revlog_origin (id INTEGER PRIMARY KEY, origin TEXT NOT NULL);
```

Each `revlog` row has exactly one row here (`id` = `revlog.id`):

- `fushi`: the review was answered in Fushi.
- `anki`: the review was imported from an Anki collection or `.apkg`, keeping Anki's original revlog id,
  rating, and duration.
- A different string can come from a future Fushi version. Please keep it as-is.

The whole file is Fushi data, but you may want to separate the `anki` rows.

## 5. `fushi_donation_meta`

```sql
CREATE TABLE fushi_donation_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

| key | value |
|---|---|
| `format` | `fushi-srs-donation` |
| `version` | `1` |
| `donor_id` | the anonymous donor id (same as the file name) |
| `exported_at` | export time in epoch ms |
| `app_version` | Fushi app version |
| `scheduler` | `fushi-fsrs` (constant; see section 6.2) |
| `utc_offset_min` | UTC offset in minutes, east positive (for example `540` for JST) |
| `rollover_hour` | the hour (0–23, local time) when a new review day starts |

## 6. Differences from native Anki

### 6.1 Review days

Fushi uses the same day model as Anki: a day starts at `rollover_hour` local time. To compute the review day for
a review:

```
day = floor((revlog.id + utc_offset_min * 60000 - rollover_hour * 3600000) / 86400000)
```

The same values are also in `col.conf`, using Anki's convention: `rollover` = `rollover_hour`, and
`creationOffset` = `localOffset` = `-utc_offset_min` (minutes **west** of UTC).

Limitation: the file contains one fixed offset, the device's offset at export time. There is no daylight-saving
adjustment and no per-review offset. Reviews from before a donor moved time zones, or from the other side of a
daylight-saving change, can be off by the difference.

### 6.2 Scheduler

Fushi schedules with its own FSRS implementation, based on fsrs-rs. Each deck uses one of these algorithms:

- FSRS-6;
- FSRS-7;
- RWKV (anki-rwkv's model, with an FSRS-7 shadow state).

Fushi does not use SM-2. As a result:

- `ivl` and `lastIvl` show what Fushi scheduled, so they are not comparable to SM-2 intervals.
- `factor` carries no information (section 3).
- The algorithm is not recorded per review. `meta.scheduler` is the constant `fushi-fsrs`. The only clue in the
  file is `rwkvReviewEnabled` on a preset.

Reviews imported from Anki were scheduled by Anki. Their `ivl` is Anki's value, rounded to whole days for
review-queue answers.

### 6.3 Learning steps

- Default steps are 1 m and 10 m. They are in `dconf.new.delays` and `dconf.lapse.delays`.
- RWKV decks without explicit steps have **no** learning steps. New cards and lapsed cards go straight to the
  review queue, so you will see `type = 0` or `type = 2` rows followed directly by day intervals.
- Native Fushi reviews never have `type = 3`: their type is always derived from the queue the card was in before the answer.

### 6.4 Durations

- The exporter writes the stored duration as-is, with no 60 s cap.
- **However**, Fushi's reviewer currently caps the recorded value at 60 000 ms when it saves a native review, the
  same as Anki's default `maxTaken`. So `fushi` rows are 0–60 000 ms in practice.
- Rows imported from Anki carry whatever Anki recorded, so they were also capped by that collection's `maxTaken`.
- The timer starts when the card is shown and stops when it is answered.

### 6.5 Dropped data

The file contains no manual reschedules, no tags, no deck, preset, or note-type names, no card text other than
section 7, no media, no FSRS memory states, and no Fushi-only metadata.

## 7. Headword and reading

These are optional. The donor can switch them off or exclude individual words.

- In each note type, at most one field is named `Headword` and at most one is named `Reading`. These are the fields
  that **could** hold the word. The name is given even when the value is blank.
- Fushi's built-in note types use fixed fields (`Expression` / `ExpressionReading`). For other note types, a field
  is used if its name matches an allow-list (for example `Expression`, `Word`, `Vocab`, `Kanji`, `単語`, `表記` for
  headwords, and `Reading`, `Kana`, `読み`, `かな` for readings). The first match is used.
- Values are plain text with HTML stripped and whitespace trimmed. A value is kept only if it passes these checks:
  - **headword**: 1–15 characters, all hiragana, katakana, kanji, or `ー々〆ヶ`;
  - **reading**: 1–15 characters, kana and `ー` only.

  Anything with spaces, punctuation, Latin letters, digits, or brackets (for example `漢字[かんじ]`) is blanked.
  A reading is kept only if the headword is kept.
- **A blank value means "unknown"**, not "no word". The value may have failed validation, the donor may have
  excluded the note or disabled words, or the note type may have no matching field.

## 8. Deduplication

Use `revlog.id`:

- For rows imported from Anki (`origin = anki`), it is the original Anki revlog id. These rows overlap with any
  direct Anki donation from the same person and merge on that id.
- For `fushi` rows, it is the real answer time in ms. It is unique within a file, apart from the rare +1 ms
  shift.

Do not dedupe on `cid` or `nid`, because these ids differ from the ids in the original Anki collection (section 3).
Across batches, a donor's file replaces their earlier file (section 1).

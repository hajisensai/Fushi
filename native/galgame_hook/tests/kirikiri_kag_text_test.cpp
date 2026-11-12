// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// KiriKiri classic KAG3 text lane: wire parsing, line assembly at KAG click
// waits, reset on clear, ruby, dedupe, overflow fail-closed, admission and the
// lane write itself.  Synthetic text only.
//
// argv[1] = tests/fixtures/kirikiri_kag_text_replay.tsv
#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <sstream>
#include <string>
#include <vector>

#include "../hook/adapters/kirikiri_kag_text_core.h"

namespace kt = fushi_voice_hook::kirikiri_kag_text;

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool condition, const std::string& what) {
  ++g_checks;
  if (!condition) {
    ++g_failures;
    fprintf(stderr, "FAIL: %s\n", what.c_str());
  }
}

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                    static_cast<int>(utf8.size()), nullptr, 0);
  assert(n > 0);
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                      static_cast<int>(utf8.size()), out.data(), n);
  return out;
}

// Fixture text: UTF-8 with {U+XXXX} standing for one UTF-16 unit (editors and
// tools strip trailing whitespace, which is exactly what some cases test).
std::wstring FixtureText(const std::string& utf8) {
  std::wstring out;
  size_t pos = 0;
  while (pos < utf8.size()) {
    const size_t open = utf8.find("{U+", pos);
    if (open == std::string::npos) {
      out += Widen(utf8.substr(pos));
      break;
    }
    const size_t close = utf8.find('}', open);
    assert(close != std::string::npos);
    out += Widen(utf8.substr(pos, open - pos));
    out += static_cast<wchar_t>(std::stoul(utf8.substr(open + 3, close - open - 3),
                                            nullptr, 16));
    pos = close + 1;
  }
  return out;
}

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                    static_cast<int>(wide.size()), nullptr, 0,
                                    nullptr, nullptr);
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}

// The same record shape the TJS fushiKagTextEmit builds.
std::wstring Record(wchar_t op, uint32_t id, const std::wstring& payload) {
  std::wstring out(1, op);
  out += std::to_wstring(id);
  out += L",";
  out += std::to_wstring(payload.size());
  out += L":";
  out += payload;
  return out;
}

std::vector<std::wstring> Apply(kt::Assembler* assembler,
                                const std::wstring& batch,
                                kt::BatchStatus* status = nullptr) {
  auto lines = std::make_unique<kt::LineBatch>();
  const kt::BatchStatus result = kt::ApplyBatch(
      assembler, batch.data(), static_cast<uint32_t>(batch.size()), lines.get());
  if (status != nullptr) *status = result;
  std::vector<std::wstring> out;
  for (uint32_t i = 0; i < lines->count; ++i) {
    out.emplace_back(lines->lines[i].text, lines->lines[i].units);
  }
  return out;
}

std::vector<std::string> SplitTabs(const std::string& line) {
  std::vector<std::string> out;
  size_t start = 0;
  while (true) {
    const size_t tab = line.find('\t', start);
    out.push_back(line.substr(start, tab - start));
    if (tab == std::string::npos) break;
    start = tab + 1;
  }
  return out;
}

int RunFixture(const char* path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    fprintf(stderr, "cannot open fixture %s\n", path);
    return -1;
  }
  int cases = 0;
  std::string name;
  auto assembler = std::make_unique<kt::Assembler>();
  std::wstring pending;
  std::vector<std::wstring> committed;
  size_t consumed = 0;
  auto flush = [&]() {
    const std::vector<std::wstring> lines = Apply(assembler.get(), pending);
    committed.insert(committed.end(), lines.begin(), lines.end());
    pending.clear();
  };
  std::string raw;
  while (std::getline(in, raw)) {
    if (!raw.empty() && raw.back() == '\r') raw.pop_back();
    if (raw.empty() || raw[0] == '#') continue;
    const std::vector<std::string> f = SplitTabs(raw);
    const std::string& op = f[0];
    if (op == "case") {
      name = f.at(1);
      assembler->Reset();
      pending.clear();
      committed.clear();
      consumed = 0;
    } else if (op == "c") {
      const uint32_t id = static_cast<uint32_t>(std::stoul(f.at(1)));
      const std::wstring text = FixtureText(f.at(2));
      for (size_t i = 0; i < text.size(); ++i) {
        size_t n = 1;
        if (IS_HIGH_SURROGATE(text[i]) && i + 1 < text.size()) n = 2;
        pending += Record(L'c', id, text.substr(i, n));
        i += n - 1;
      }
    } else if (op == "s" || op == "r") {
      pending += Record(op[0] == 's' ? L'c' : L'r',
                        static_cast<uint32_t>(std::stoul(f.at(1))),
                        FixtureText(f.at(2)));
    } else if (op == "w" || op == "x") {
      pending += Record(static_cast<wchar_t>(op[0]),
                        static_cast<uint32_t>(std::stoul(f.at(1))), L"");
    } else if (op == "o") {
      pending += Record(L'o', 0, L"");
    } else if (op == "flush") {
      flush();
    } else if (op == "expect") {
      flush();
      const std::wstring want = FixtureText(f.at(1));
      const bool have = consumed < committed.size();
      Check(have && committed[consumed] == want,
            name + ": expected \"" + f.at(1) + "\" got \"" +
                (have ? Narrow(committed[consumed]) : std::string("<none>")) +
                "\"");
      ++consumed;
    } else if (op == "end") {
      flush();
      Check(consumed == committed.size(),
            name + ": " + std::to_string(committed.size() - consumed) +
                " unexpected extra line(s)" +
                (consumed < committed.size()
                     ? std::string(", first \"") + Narrow(committed[consumed]) + "\""
                     : std::string()));
      ++cases;
    } else {
      fprintf(stderr, "fixture: unknown op '%s'\n", op.c_str());
      return -1;
    }
  }
  return cases;
}

void TestMalformedBatchFailsClosed() {
  auto assembler = std::make_unique<kt::Assembler>();
  kt::BatchStatus status = kt::BatchStatus::kOk;
  // A record whose declared length runs past the batch end.
  std::wstring batch = Record(L'c', 1, L"あ") + L"c1,5:い";
  std::vector<std::wstring> lines = Apply(assembler.get(), batch, &status);
  Check(status == kt::BatchStatus::kMalformed, "truncated record is malformed");
  Check(lines.empty(), "truncated record publishes nothing");
  // The interrupted line must not be published at the next wait.
  lines = Apply(assembler.get(), Record(L'w', 1, L""));
  Check(lines.empty(), "line interrupted by a malformed batch is dropped");
  lines = Apply(assembler.get(), Record(L'c', 1, L"う") + Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == L"う", "next line after malformed batch");

  // Unknown op and missing separators.
  for (const wchar_t* bad : {L"q1,0:", L"c1:0", L"c,0:", L"c1,0", L"c99999999,0:"}) {
    auto fresh = std::make_unique<kt::Assembler>();
    Apply(fresh.get(), Record(L'c', 1, L"え"));
    Apply(fresh.get(), bad, &status);
    Check(status == kt::BatchStatus::kMalformed,
          "malformed record rejected: " + Narrow(bad));
    Check(Apply(fresh.get(), Record(L'w', 1, L"")).empty(),
          "pending text dropped after: " + Narrow(bad));
  }
}

void TestOverlongLineIsNeverPublishedAsPrefix() {
  auto assembler = std::make_unique<kt::Assembler>();
  std::wstring batch;
  for (uint32_t i = 0; i < kt::kMaxLineUnits + 5u; ++i) {
    batch += Record(L'c', 1, L"あ");
  }
  batch += Record(L'w', 1, L"");
  std::vector<std::wstring> lines = Apply(assembler.get(), batch);
  Check(lines.empty(), "line over the slot capacity is dropped, not truncated");
  lines = Apply(assembler.get(), Record(L'c', 1, L"い") + Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == L"い", "capacity poison ends at the wait");

  // A processCh payload far longer than any character is not a character.
  assembler->Reset();
  lines = Apply(assembler.get(),
                Record(L'c', 1, std::wstring(kt::kMaxCharPayloadUnits + 1u, L'x')) +
                    Record(L'w', 1, L""));
  Check(lines.empty(), "oversized processCh payload poisons the line");
}

void TestControlCharactersNeverReachTheLine() {
  auto assembler = std::make_unique<kt::Assembler>();
  const std::wstring batch = Record(L'c', 1, L"あ") + Record(L'c', 1, L"\n") +
                             Record(L'c', 1, L"\x1b") + Record(L'c', 1, L"い") +
                             Record(L'w', 1, L"");
  const std::vector<std::wstring> lines = Apply(assembler.get(), batch);
  Check(lines.size() == 1 && lines[0] == L"あい", "control units are dropped");
}

void TestSurrogatePairsSurvive() {
  auto assembler = std::make_unique<kt::Assembler>();
  const std::wstring pair = L"\xD842\xDFB7";  // U+20BB7
  const std::vector<std::wstring> lines = Apply(
      assembler.get(), Record(L'c', 1, pair) + Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == pair, "surrogate pair kept intact");
}

void TestBatchLineCapNeverTruncates() {
  auto assembler = std::make_unique<kt::Assembler>();
  std::wstring batch;
  for (uint32_t i = 0; i < kt::kMaxLinesPerBatch + 3u; ++i) {
    batch += Record(L'c', 1, L"あ") + Record(L'w', 1, L"");
  }
  const std::vector<std::wstring> lines = Apply(assembler.get(), batch);
  Check(lines.size() == kt::kMaxLinesPerBatch, "batch line cap respected");
  for (const std::wstring& line : lines) Check(line == L"あ", "capped lines whole");
}

void TestLayerTableEvictionStaysPerLayer() {
  auto assembler = std::make_unique<kt::Assembler>();
  std::wstring batch;
  for (uint32_t id = 1; id <= kt::kMaxLayers + 4u; ++id) {
    batch += Record(L'c', id, L"か");
  }
  batch += Record(L'c', kt::kMaxLayers + 4u, L"き");
  batch += Record(L'w', kt::kMaxLayers + 4u, L"");
  const std::vector<std::wstring> lines = Apply(assembler.get(), batch);
  Check(lines.size() == 1 && lines[0] == L"かき",
        "most recent layer keeps its own text under eviction");
  Check(assembler->PendingUnits(1) == 0u, "evicted layer holds nothing");
}

// Non-KiriKiri negative: no TJS exporter means no lane, whatever else holds.
// The exporter only exists where the engine handed us its TVP plugin ABI.
void TestAdmissionRequiresTheKirikiriExporter() {
  Check(kt::LaneWanted(false, true, true, true), "KiriKiri session admitted");
  Check(!kt::LaneWanted(false, true, false, true), "no exporter -> no lane");
  Check(!kt::LaneWanted(true, true, true, true), "stopping -> no lane");
  Check(!kt::LaneWanted(false, false, true, true), "capture off -> no lane");
  Check(!kt::LaneWanted(false, true, true, false), "no shared header -> no lane");
}

// A non-KAG KiriKiri script stream (no click waits ever) yields nothing.
void TestNoWaitSeamMeansSilence() {
  auto assembler = std::make_unique<kt::Assembler>();
  std::wstring batch;
  for (int i = 0; i < 200; ++i) batch += Record(L'c', 1, L"ぶ");
  batch += Record(L'x', 1, L"");
  for (int i = 0; i < 200; ++i) batch += Record(L'c', 2, L"ん");
  Check(Apply(assembler.get(), batch).empty(), "no wait -> no line");
}

struct FakeMapping {
  std::vector<uint8_t> bytes;
  FakeMapping() {
    const uint64_t text_bytes = fushi_voice_hook::TextRegionBytes(
        fushi_voice_hook::kTextLaneCount, fushi_voice_hook::kTextLaneSlotCount);
    bytes.assign(
        static_cast<size_t>(sizeof(fushi_voice_hook::SharedHeader) + text_bytes), 0);
    auto* h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = fushi_voice_hook::kSharedVersion;
    h->text_region_offset =
        static_cast<uint32_t>(sizeof(fushi_voice_hook::SharedHeader));
    h->text_lane_count = fushi_voice_hook::kTextLaneCount;
    h->text_lane_slot_count = fushi_voice_hook::kTextLaneSlotCount;
  }
  fushi_voice_hook::SharedHeader* header() {
    return reinterpret_cast<fushi_voice_hook::SharedHeader*>(bytes.data());
  }
};

void TestLaneWriteIsAnEngineExactLane() {
  const std::wstring code = kt::kHookCode;
  Check(code.rfind(L"ENGINE:", 0) == 0, "hook code carries the ENGINE: prefix");
  Check(code == L"ENGINE:KIRIKIRI:kag_message", "hook code is frozen");
  const uint64_t thread = kt::LaneThreadId();
  Check((thread & fushi_voice_hook::kNativeTextThreadNamespaceBit) != 0,
        "native text thread namespace");
  Check((thread >> 63) == 0, "thread id survives signed int64");
  Check(thread == kt::LaneThreadId(), "thread id is stable");

  auto line = std::make_unique<kt::Line>();
  const std::wstring text = L"「テスト」";
  line->units = static_cast<uint32_t>(text.size());
  memcpy(line->text, text.data(), text.size() * sizeof(wchar_t));
  const fushi_voice_hook::TextLaneWrite write = kt::MakeLaneWrite(*line, 4321);
  Check(write.source_kind == fushi_voice_hook::kTextSourceKirikiri,
        "source kind is KiriKiri");
  Check(write.source_kind == 18u, "source kind wire id 18");
  Check(write.is_utf8 == 0, "UTF-16 payload");
  Check(write.byte_len == text.size() * sizeof(wchar_t), "byte length");

  FakeMapping mapping;
  const uint64_t seq = fushi_voice_hook::WriteTextLaneEvent(
      mapping.header(), fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  Check(seq != 0, "lane write accepted");
  fushi_voice_hook::TextLane* lanes = fushi_voice_hook::TextLanesOf(mapping.header());
  bool found = false;
  for (uint32_t i = 0; i < mapping.header()->text_lane_count; ++i) {
    if (lanes[i].thread_id != thread) continue;
    auto* slot = reinterpret_cast<fushi_voice_hook::TextSlot*>(
        fushi_voice_hook::TextLaneSlotAt(mapping.header(), i, lanes[i].write_count));
    if (slot == nullptr) continue;
    found = true;
    Check(i >= fushi_voice_hook::kNativeThreadPreviewStart,
          "written in the native lane partition");
    Check(std::wstring(slot->hook_code) == code, "slot hook code");
    Check(std::string(slot->hook_name) == kt::kHookName, "slot hook name");
    Check(slot->source_kind == fushi_voice_hook::kTextSourceKirikiri,
          "slot source kind");
    const auto* stored = reinterpret_cast<const wchar_t*>(
        reinterpret_cast<const uint8_t*>(slot) + sizeof(fushi_voice_hook::TextSlot));
    Check(std::wstring(stored, slot->byte_len / sizeof(wchar_t)) == text,
          "slot text untruncated");
  }
  Check(found, "lane slot readable");

  // The longest committable line still fits one slot untruncated.
  auto longest = std::make_unique<kt::Line>();
  longest->units = kt::kMaxLineUnits;
  for (uint32_t i = 0; i < longest->units; ++i) longest->text[i] = L'あ';
  FakeMapping second;
  const fushi_voice_hook::TextLaneWrite long_write = kt::MakeLaneWrite(*longest, 1);
  Check(fushi_voice_hook::WriteTextLaneEvent(
            second.header(), fushi_voice_hook::kNativeThreadPreviewStart,
            fushi_voice_hook::kTextLaneCount, long_write) != 0,
        "longest line accepted");
  lanes = fushi_voice_hook::TextLanesOf(second.header());
  for (uint32_t i = 0; i < second.header()->text_lane_count; ++i) {
    if (lanes[i].thread_id != thread) continue;
    auto* slot = reinterpret_cast<fushi_voice_hook::TextSlot*>(
        fushi_voice_hook::TextLaneSlotAt(second.header(), i, lanes[i].write_count));
    Check(slot != nullptr && slot->byte_len == kt::kMaxLineUnits * sizeof(wchar_t),
          "longest line stored whole");
  }
}

// Every commit point lands in exactly one outcome bucket, so the on-device
// stats line can tell "no characters", "characters lost" and "no wait" apart.
void TestOutcomeCountersClassifyEveryCommit() {
  auto assembler = std::make_unique<kt::Assembler>();
  // One wait seen by two seams (showLineBreak, then its own conductor.wait):
  // one line, the second commit is blank -- never a duplicate.
  std::vector<std::wstring> lines = Apply(
      assembler.get(), Record(L'c', 1, L"あ") + Record(L'c', 1, L"い") +
                           Record(L'w', 1, L"") + Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == L"あい", "double-seen wait commits once");
  kt::AssemblerCounters c = assembler->counters();
  Check(c.chars == 2 && c.waits == 2 && c.lines == 1 && c.blank_waits == 1,
        "line + blank counted");
  // A wait on a layer that never drew is blank.
  Apply(assembler.get(), Record(L'w', 7, L""));
  Check(assembler->counters().blank_waits == 2, "unseen layer wait is blank");
  // Characters lost upstream: the commit is counted as poisoned, not blank.
  Apply(assembler.get(), Record(L'c', 1, L"う"));
  assembler->Overflow();
  Apply(assembler.get(), Record(L'c', 1, L"え") + Record(L'w', 1, L""));
  c = assembler->counters();
  Check(c.poisoned_waits == 1 && c.overflows == 1 && c.lines == 1,
        "poisoned commit counted");
  Apply(assembler.get(), Record(L'x', 1, L""));
  Check(assembler->counters().clears == 1, "clear counted");
  Check(c.waits == c.lines + c.poisoned_waits + c.blank_waits + c.capped_waits,
        "every wait has exactly one outcome");
  // Batch cap: lines past the cap are counted, not silently lost.
  auto capped = std::make_unique<kt::Assembler>();
  std::wstring batch;
  for (uint32_t i = 0; i < kt::kMaxLinesPerBatch + 2u; ++i) {
    batch += Record(L'c', 1, L"お") + Record(L'w', 1, L"");
  }
  Apply(capped.get(), batch);
  Check(capped->counters().capped_waits == 2, "capped commits counted");
}

void TestStatsLineShape() {
  const std::wstring good = L"pc=12,cur=10,over=0,lb=1,pb=0,w=1,w0=0,faults=0";
  Check(kt::IsLoggableStats(good.c_str(), static_cast<uint32_t>(good.size())),
        "integer stats line is loggable");
  for (const wchar_t* bad : {L"", L"pc=1 cur=2", L"pc=\x3042", L"error\n", L"PC=1"}) {
    Check(!kt::IsLoggableStats(bad, static_cast<uint32_t>(wcslen(bad))),
          "non-stats text is not logged: " + Narrow(bad));
  }
  const std::wstring longest(kt::kMaxStatsUnits, L'1');
  Check(!kt::IsLoggableStats(longest.c_str(), static_cast<uint32_t>(longest.size())),
        "overlong stats line is not logged");
  auto line = std::make_unique<kt::Line>();
  line->units = 1;
  line->text[0] = L'a';
  const fushi_voice_hook::TextLaneWrite write = kt::MakeLaneWrite(*line, 1);
  Check(write.thread_address == kt::kComponentIdentity && write.thread_context != 0,
        "lane carries a stable non-zero thread address");
}

// Mirrors the TJS side's buffer discipline in kKirikiriKagTextBootstrapScript
// (fushiKagTextAppend / FlushRun / EmitChar / Emit / Take).  The source guard
// (KagTextLaneGuardTest.test_capacity_is_bounded_by_design) pins the script's
// three capacity literals to this header's constants, so the model and the
// script cannot drift apart silently.
class TjsSideModel {
 public:
  void Char(uint32_t id, const std::wstring& ch) {
    if (ch.size() > kt::kMaxCharPayloadUnits) {
      Event(L'c', id, ch);
      return;
    }
    if (run_id_ != id || run_.size() + ch.size() > kt::kMaxLineUnits) FlushRun();
    run_id_ = id;
    run_ += ch;
    ++seq;
  }
  void Event(wchar_t op, uint32_t id, const std::wstring& payload = L"") {
    FlushRun();
    Append(Record(op, id, payload));
    ++seq;
  }
  std::wstring Take() {
    FlushRun();
    std::wstring events;
    events.swap(events_);
    return events;
  }
  int64_t seq = 0;
  uint32_t overflows = 0;
  size_t peak_units = 0;

 private:
  void Append(const std::wstring& record) {
    if (events_.size() + record.size() > kt::kTjsEventBufferUnits) {
      events_ = L"o0,0:";
      ++overflows;
    } else {
      events_ += record;
    }
    if (events_.size() > peak_units) peak_units = events_.size();
  }
  void FlushRun() {
    if (run_id_ > 0 && !run_.empty()) Append(Record(L's', run_id_, run_));
    run_id_ = 0;
    run_.clear();
  }
  uint32_t run_id_ = 0;
  std::wstring run_;
  std::wstring events_;
};

struct BurstResult {
  std::vector<std::wstring> lines;
  kt::AssemblerCounters counters;
  uint32_t tjs_overflows = 0;
  uint32_t deferred = 0;
  uint32_t dropped = 0;
  size_t peak_units = 0;
};

// Frame-level replay of pump + mailbox + worker.  `chars_per_frame` characters
// are drawn each game frame (0 = the whole page in one frame, KAG nowait), the
// pump runs once per frame, HookWorker drains every `drain_every` frames.
// `legacy_drop` replays the old policy (take every frame, drop when full).
BurstResult ReplayBurst(const std::wstring& page, uint32_t chars_per_frame,
                        uint32_t drain_every, bool legacy_drop) {
  BurstResult result;
  TjsSideModel tjs;
  auto assembler = std::make_unique<kt::Assembler>();
  std::vector<std::wstring> mailbox;  // FIFO, at most kMailboxSlots
  std::vector<bool> gaps;
  bool pending_gap = false;
  int64_t taken_seq = -1;
  size_t drawn = 0;
  bool waited = false;
  const uint32_t per_frame =
      chars_per_frame == 0 ? static_cast<uint32_t>(page.size()) : chars_per_frame;
  for (uint32_t frame = 1; frame < 100000u; ++frame) {
    // Game: draw this frame's characters, then the [p] wait once all are drawn.
    for (uint32_t i = 0; i < per_frame && drawn < page.size(); ++i, ++drawn) {
      tjs.Char(1, page.substr(drawn, 1));
    }
    if (drawn == page.size() && !waited) {
      tjs.Event(L'w', 1);
      waited = true;
    }
    // Pump.
    const bool room = mailbox.size() < kt::kMailboxSlots;
    if (legacy_drop) {
      if (tjs.seq != taken_seq) {
        taken_seq = tjs.seq;
        std::wstring batch = tjs.Take();
        if (room) {
          mailbox.push_back(batch);
          gaps.push_back(pending_gap);
          pending_gap = false;
        } else {
          pending_gap = true;
          ++result.dropped;
        }
      }
    } else {
      switch (kt::NextPumpAction(tjs.seq, taken_seq, room)) {
        case kt::PumpAction::kIdle:
          break;
        case kt::PumpAction::kDefer:
          ++result.deferred;
          break;
        case kt::PumpAction::kTake:
          taken_seq = tjs.seq;
          mailbox.push_back(tjs.Take());
          gaps.push_back(false);
          break;
      }
    }
    // Worker.
    if (frame % drain_every == 0) {
      for (size_t i = 0; i < mailbox.size(); ++i) {
        if (gaps[i]) assembler->Overflow();
        auto out = std::make_unique<kt::LineBatch>();
        kt::ApplyBatch(assembler.get(), mailbox[i].data(),
                       static_cast<uint32_t>(mailbox[i].size()), out.get());
        for (uint32_t l = 0; l < out->count; ++l) {
          result.lines.emplace_back(out->lines[l].text, out->lines[l].units);
        }
      }
      mailbox.clear();
      gaps.clear();
      if (waited && tjs.seq == taken_seq) break;
    }
  }
  result.counters = assembler->counters();
  result.tjs_overflows = tjs.overflows;
  result.peak_units = tjs.peak_units;
  return result;
}

std::wstring SyntheticPage(uint32_t units) {
  std::wstring page;
  const std::wstring alphabet = L"あいうえおかきくけこさしすせそ、。「」";
  for (uint32_t i = 0; i < units; ++i) page += alphabet[i % alphabet.size()];
  return page;
}

// Real machine (a DWARF SOFT KiriKiri2 title): one character per frame while
// HookWorker drained the 8-slot mailbox every ~200 ms (12 frames at 60 fps).
// The old pump dropped every batch past the 8th and poisoned every page.
void TestBurstBetweenDrainsPublishesOneWholeLine() {
  const std::wstring page = SyntheticPage(120);
  const BurstResult legacy = ReplayBurst(page, 1, 12, true);
  Check(legacy.dropped > 0 && legacy.lines.empty(),
        "replay reproduces the old drop-and-poison failure");

  const BurstResult fixed = ReplayBurst(page, 1, 12, false);
  Check(fixed.deferred > 0, "the mailbox did fill up: backpressure was exercised");
  Check(fixed.lines.size() == 1 && fixed.lines[0] == page,
        "one complete line after a per-frame burst");
  Check(fixed.counters.poisoned_waits == 0 && fixed.counters.overflows == 0 &&
            fixed.tjs_overflows == 0,
        "no poison, no overflow under backpressure");

  // KAG nowait: a maximal page lands in one frame, between two drains.
  const std::wstring longest = SyntheticPage(kt::kMaxLineUnits);
  const BurstResult instant = ReplayBurst(longest, 0, 12, false);
  Check(instant.lines.size() == 1 && instant.lines[0] == longest,
        "a maximal page drawn in one frame is one complete line");
  Check(instant.tjs_overflows == 0 && instant.counters.poisoned_waits == 0,
        "a maximal page fits the TJS buffer");
  Check(instant.peak_units <= kt::kMaxPageEventUnits,
        "a maximal page costs at most kMaxPageEventUnits");

  // A slow worker (drains once per second) still loses nothing.
  const BurstResult slow = ReplayBurst(page, 2, 60, false);
  Check(slow.lines.size() == 1 && slow.lines[0] == page &&
            slow.counters.poisoned_waits == 0,
        "slow worker: whole line, no poison");
}

void TestRunRecords() {
  auto assembler = std::make_unique<kt::Assembler>();
  std::vector<std::wstring> lines = Apply(
      assembler.get(), Record(L's', 1, L"あ\nい") + Record(L's', 1, L"う") +
                           Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == L"あいう", "runs append, control units dropped");
  lines = Apply(assembler.get(),
                Record(L's', 1, std::wstring(kt::kMaxLineUnits + 1u, L'x')) +
                    Record(L'w', 1, L""));
  Check(lines.empty(), "a run longer than a line poisons it");
  lines = Apply(assembler.get(), Record(L's', 1, L"え") + Record(L'w', 1, L""));
  Check(lines.size() == 1 && lines[0] == L"え", "poison ends at the wait");
  Check(kt::NextPumpAction(5, 5, false) == kt::PumpAction::kIdle &&
            kt::NextPumpAction(6, 5, false) == kt::PumpAction::kDefer &&
            kt::NextPumpAction(6, 5, true) == kt::PumpAction::kTake,
        "pump action table");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <kirikiri_kag_text_replay.tsv>\n", argv[0]);
    return 2;
  }
  int cases = -1;
  try {
    cases = RunFixture(argv[1]);
  } catch (const std::exception& error) {
    fprintf(stderr, "fixture parse error: %s\n", error.what());
  }
  Check(cases >= 14, "fixture replayed (" + std::to_string(cases) + " cases)");
  TestMalformedBatchFailsClosed();
  TestOverlongLineIsNeverPublishedAsPrefix();
  TestControlCharactersNeverReachTheLine();
  TestSurrogatePairsSurvive();
  TestBatchLineCapNeverTruncates();
  TestLayerTableEvictionStaysPerLayer();
  TestAdmissionRequiresTheKirikiriExporter();
  TestNoWaitSeamMeansSilence();
  TestLaneWriteIsAnEngineExactLane();
  TestOutcomeCountersClassifyEveryCommit();
  TestStatsLineShape();
  TestRunRecords();
  TestBurstBetweenDrainsPublishesOneWholeLine();
  if (g_failures != 0) {
    fprintf(stderr, "%d of %d checks failed\n", g_failures, g_checks);
    return 1;
  }
  printf("kirikiri_kag_text_test: %d fixture cases, %d checks passed\n", cases,
         g_checks);
  return 0;
}

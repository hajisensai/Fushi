#include "siglus_eightarg_message_capture.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

namespace {
namespace capture = fushi_voice_hook::siglus_eightarg_message;
unsigned checks = 0;
void Check(bool condition, const char* why) {
  ++checks;
  if (!condition) { std::fprintf(stderr, "FAIL: %s (%u)\n", why, checks); std::exit(91); }
}
struct Reader {
  std::map<uint32_t, uint32_t> words;
  std::vector<uint32_t> addresses;
  size_t fail_on = 0;
  bool operator()(uint32_t address, uint32_t* value) {
    addresses.push_back(address);
    if (addresses.size() == fail_on || !value || (address & 3u) != 0 ||
        address > UINT32_MAX - 3) return false;
    const auto found = words.find(address);
    if (found == words.end()) return false;
    *value = found->second;
    return true;
  }
};
struct Fixture {
  capture::Layout layout{0x500111, 0x600222};
  uint32_t owner = 0x20000, outer = 0x40000, inner = 0x3fe00;
  uint32_t begin = 0x80000, count = 3, index = 1;
  Reader reader;
  capture::Ticket ticket{};
  Fixture() { Populate(); }
  uint32_t Surface() const { return begin + index * 0x124; }
  void Populate() {
    reader.words.clear();
    reader.words[owner + 0x160] = index;
    reader.words[owner + 0x1a8] = begin;
    reader.words[owner + 0x1ac] = begin + count * 0x124;
    reader.words[outer] = layout.message_return;
    reader.words[inner] = layout.scenario_return;
    reader.words[inner + 4] = outer + 0xc;
    // There are no readable TextUnion bytes or selector/voice slots. This
    // ticket proves the call scope; the caller must copy text separately.
  }
  bool Arm() { return capture::Arm(layout, owner, outer, reader, &ticket); }
  bool Consume(capture::Owner* out, uint32_t* text) {
    return capture::Consume(layout, Surface(), inner, outer - 4, reader, &ticket, out, text);
  }
  void CheckNoReplay() {
    Populate(); reader.fail_on = 0;
    capture::Owner out{1, 2, 3, 4, 5}; uint32_t text = 9;
    Check(!Consume(&out, &text), "consumed/rejected ticket never replays after memory repair");
    const capture::Owner empty{};
    Check(capture::Same(out, empty) && text == 0 && !ticket.armed,
          "failure clears owner and text output");
  }
  void RejectConsume(uint32_t surface, uint32_t esp, uint32_t ebp) {
    capture::Owner out{1, 2, 3, 4, 5}; uint32_t text = 9;
    Check(!capture::Consume(layout, surface, esp, ebp, reader, &ticket, &out, &text),
          "wrong call scope rejected");
    Check(capture::Same(out, capture::Owner{}) && text == 0 && !ticket.armed,
          "all failed consumes clear outputs and consume ticket");
    CheckNoReplay();
  }
  void RejectConsume() { RejectConsume(Surface(), inner, outer - 4); }
};

void TestNormalAndIsolation() {
  Fixture f; capture::Owner out{}; uint32_t text = 0;
  Check(f.Arm(), "proved outer caller arms");
  Check(f.ticket.armed && f.ticket.entry_esp == f.outer &&
        f.ticket.owner.address == f.owner && f.ticket.owner.surface == f.Surface(), "selected owner ticket");
  capture::Ticket other_thread{};
  Check(!capture::Consume(f.layout, f.Surface(), f.inner, f.outer - 4, f.reader,
        &other_thread, &out, &text) && f.ticket.armed, "independent thread ticket cannot steal occurrence");
  Check(f.Consume(&out, &text), "direct message-to-scenario frame consumes");
  Check(out.address == f.owner && out.surface_index == 1 && out.surface_begin == f.begin &&
        out.surface_end == f.begin + 3 * 0x124 && out.surface == f.Surface(), "correct selected surface");
  Check(text == f.outer + 0xc && !f.ticket.armed, "by-value union begins at entry ESP+C");
  f.CheckNoReplay();
  Check(f.Arm() && f.Consume(&out, &text), "fresh same-owner/same-stack call is a new occurrence");
  // The primitive never evaluates the selector or reads text/audio contents.
  for (uint32_t address : f.reader.addresses) {
    Check(address == f.outer || address == f.inner || address == f.inner + 4 ||
          address == f.owner + 0x160 || address == f.owner + 0x1a8 || address == f.owner + 0x1ac,
          "bounded metadata-only reads");
  }
}

void TestArmFailures() {
  for (size_t fail = 1; fail <= 4; ++fail) {
    Fixture f; Check(f.Arm(), "old ticket armed before failing invocation");
    f.reader.fail_on = f.reader.addresses.size() + fail;
    Check(!f.Arm() && !f.ticket.armed, "each outer read failure revokes old ticket");
    f.CheckNoReplay();
  }
  { Fixture f; Check(f.Arm(), "old ticket"); f.reader.words[f.outer] ^= 1;
    Check(!f.Arm() && !f.ticket.armed, "wrong outer caller clears prior ticket"); f.CheckNoReplay(); }
  for (uint32_t esp : {0u, 0x1cu, 0x10001u, UINT32_MAX - 0x20u}) {
    Fixture f; Check(f.Arm(), "old ticket");
    Check(!capture::Arm(f.layout, f.owner, esp, f.reader, &f.ticket) && !f.ticket.armed,
          "invalid outer stack clears prior ticket"); f.CheckNoReplay();
  }
  for (int gate = 0; gate < 2; ++gate) {
    Fixture f; Check(f.Arm(), "old ticket");
    auto bad = f.layout;
    if (gate == 0) bad.message_return = 0; else bad.scenario_return = 0;
    Check(!capture::Arm(bad, f.owner, f.outer, f.reader, &f.ticket) && !f.ticket.armed,
          "incomplete layout cannot arm"); f.CheckNoReplay();
  }
  Fixture f; Check(!capture::Arm(f.layout, f.owner, f.outer, f.reader,
                               static_cast<capture::Ticket*>(nullptr)), "null arm ticket");
}

void TestConsumeFailures() {
  for (size_t fail = 1; fail <= 6; ++fail) {
    Fixture f; Check(f.Arm(), "arm before consume fault");
    f.reader.fail_on = f.reader.addresses.size() + fail;
    f.RejectConsume();
  }
  for (int changed = 0; changed < 6; ++changed) {
    Fixture f; Check(f.Arm(), "arm before runtime drift");
    switch (changed) {
      case 0: f.reader.words[f.inner] ^= 1; break;
      case 1: f.reader.words[f.outer] ^= 1; break;
      case 2: f.reader.words[f.inner + 4] += 4; break;
      case 3: f.reader.words[f.owner + 0x160] = 2; break;
      case 4: f.reader.words[f.owner + 0x1a8] += 0x124;
              f.reader.words[f.owner + 0x1ac] += 0x124; break;
      case 5: f.reader.words[f.owner + 0x1ac] += 0x124; break;
    }
    f.RejectConsume();
  }
  { Fixture f; Check(f.Arm(), "arm"); f.RejectConsume(f.Surface() + 0x124, f.inner, f.outer - 4); }
  { Fixture f; Check(f.Arm(), "arm"); f.RejectConsume(f.Surface(), f.inner, f.outer); }
  { Fixture f; Check(f.Arm(), "arm"); f.RejectConsume(f.Surface(), f.inner, f.outer - 8); }
  for (uint32_t esp : {0u, 0xfffcu, 0x40000u, 0x3ffffu, UINT32_MAX}) {
    Fixture f; Check(f.Arm(), "arm"); f.RejectConsume(f.Surface(), esp, f.outer - 4);
  }
  for (int missing = 0; missing < 2; ++missing) {
    Fixture f; Check(f.Arm(), "arm"); capture::Owner out{1,2,3,4,5}; uint32_t text = 9;
    Check(!capture::Consume(f.layout, f.Surface(), f.inner, f.outer - 4, f.reader,
        &f.ticket, missing == 0 ? nullptr : &out, missing == 1 ? nullptr : &text), "missing output consumes too");
    Check(!f.ticket.armed && (missing == 0 ? text == 0 : capture::Same(out, capture::Owner{})),
          "remaining output still cleared"); f.CheckNoReplay();
  }
  // A new layout cannot inherit the prior frame's armed occurrence, even if
  // game memory has already changed to match the new return addresses.
  for (int changed = 0; changed < 2; ++changed) {
    Fixture f; Check(f.Arm(), "arm before profile replacement");
    if (changed == 0) f.layout.message_return += 4;
    else f.layout.scenario_return += 4;
    f.Populate(); f.RejectConsume();
  }
  Fixture f; capture::Owner out{1,2,3,4,5}; uint32_t text = 9;
  Check(!capture::Consume(f.layout, f.Surface(), f.inner, f.outer - 4, f.reader,
      static_cast<capture::Ticket*>(nullptr), &out, &text) &&
      capture::Same(out, capture::Owner{}) && text == 0, "null ticket clears outputs");
}

void TestOwnerBounds() {
  for (uint32_t owner : {0u, 0xfffcu, 0x10001u, 0xfffffffcu}) {
    Fixture f; capture::Owner out{1,2,3,4,5};
    Check(!capture::ReadOwner(owner, f.reader, &out) && capture::Same(out, capture::Owner{}),
          "invalid/overflow owner rejected and cleared");
  }
  for (int bad = 0; bad < 8; ++bad) {
    Fixture f;
    switch (bad) {
      case 0: f.reader.words[f.owner + 0x1a8] = 0; break;
      case 1: f.reader.words[f.owner + 0x1a8] = 0x10001; break;
      case 2: f.reader.words[f.owner + 0x1ac] = f.begin; break;
      case 3: f.reader.words[f.owner + 0x1ac] = f.begin - 4; break;
      case 4: f.reader.words[f.owner + 0x1ac] += 4; break;
      case 5: f.reader.words[f.owner + 0x1ac] = f.begin + 257 * 0x124; break;
      case 6: f.reader.words[f.owner + 0x160] = 3; break;
      case 7: f.reader.words[f.owner + 0x160] = UINT32_MAX; break;
    }
    Check(!f.Arm() && !f.ticket.armed, "malformed surface vector cannot arm"); f.CheckNoReplay();
  }
  { Fixture f; f.count = 256; f.index = 255; f.begin = 0xfffffffcu - f.count * 0x124;
    f.owner = 0xfffffffcu - 0x1ac; f.Populate();
    capture::Owner out{}; uint32_t text = 0;
    Check(f.Arm() && f.Consume(&out, &text) && out.surface == f.Surface(),
          "maximum count, last index, exact upper-address owner/vector fit"); }
  { Fixture f; f.outer = (UINT32_MAX - 0x24u) & ~3u; f.inner = f.outer - 0x100; f.Populate();
    capture::Owner out{}; uint32_t text = 0;
    Check(f.Arm() && f.Consume(&out, &text) && text == f.outer + 0xc, "bounded high stack text union"); }
}
}  // namespace

int main() {
  TestNormalAndIsolation(); TestArmFailures(); TestConsumeFailures(); TestOwnerBounds();
  std::printf("siglus_eightarg_message_capture_test: PASS (%u checks)\n", checks);
}

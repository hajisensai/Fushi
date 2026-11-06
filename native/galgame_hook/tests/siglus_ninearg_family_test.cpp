#include <windows.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdio>
#include "siglus_ninearg_family.h"

// Synthetic protector-shaped image: every anchor, edge, slot and jump table is
// written from the resolver's own contract, so each mutation below removes
// exactly one proof. No game bytes are embedded.
namespace {
using namespace fushi_voice_hook;
namespace na = fushi_voice_hook::siglus_ninearg;
namespace glyph = fushi_voice_hook::siglus_legacy_glyph;
namespace input = fushi_voice_hook::siglus_legacy_input_viewport;
constexpr uintptr_t kSize = 0x12000, kData = 0x10000;
struct Layout {
  uintptr_t entry=0x1000, font=0x1080, coordinates=0x1100, glyph_return=0x1200;
  uintptr_t dialogue=0x1400, render=0x1600, first=0x1640, second=0x1740;
  uintptr_t render_exit=0x1840, group=0x1a00, group_owners=0x1a40;
  uintptr_t normal=0x1c00, text=0x2000, message=0x2600, sampler=0x2a00;
  uintptr_t input_message=0x2e00, main=0x3000, normalize=0x3100;
  uintptr_t design=0x3300, owner=0x3400, visibility=0x3480, gate=0x3500;
  uintptr_t helper=0x3800, shared=0x3810, other=0x3820;
  uintptr_t cookie=kData, config=kData+0x10, manager=kData+0x14;
  uintptr_t owner_a=kData+0x18, owner_b=kData+0x1c, input_slot=kData+0x20;
  uintptr_t window=kData+0x24, modal=kData+0x28, auxiliary=kData+0x2c;
  uintptr_t hidden=kData+0x30, cursor=kData+0x34, active=kData+0x38;
  uintptr_t key=kData+0x3c, screen=kData+0x40, table=kData+0x100;
};
constexpr uint32_t kTable[] = {0x2c, 0x3c, 0xe9, 0xe9, 0x2c, 0x3c, 0x8c, 0xe9,
                               0x9c, 0xac, 0xe9, 0xbc, 0xcc, 0xe9, 0xdc};
unsigned checks = 0;

struct Image {
  uint8_t* bytes=static_cast<uint8_t*>(VirtualAlloc(
      nullptr,kSize,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  Layout p;
  explicit Image(bool merged=false,uintptr_t base=0x110000) {
    assert(bytes);std::memset(bytes,0xcc,kSize);std::memset(bytes+kData,0,kSize-kData);
    view.base=bytes;view.absolute_base=base;view.size=kSize;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;
    if(merged){
      // Protector-merged: data, tables and code share one executable section.
      view.section_count=1;
      view.sections[0]={bytes+0x1000,kSize-0x1000,0x1000,
          IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    }else{
      view.section_count=2;
      view.sections[0]={bytes+0x1000,kData-0x1000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
      view.sections[1]={bytes+kData,kSize-kData,kData,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    }
    for(auto at:{p.helper,p.shared,p.other})bytes[at]=0xc3;
    // Glyph body: disabled branch -> RET 0x24 epilogue; font then coordinates.
    Put(p.entry,na::kGlyphEntry.pattern());Put(p.font,na::kGlyphFont.pattern());
    Put(p.coordinates,na::kGlyphCoordinates.pattern());
    Put(p.glyph_return,na::kGlyphReturn.pattern());
    Word(p.entry+58,static_cast<uint32_t>(p.glyph_return-p.entry-62));
    Address(p.entry+3,p.helper);Address(p.entry+25,p.cookie);
    Address(p.coordinates+11,p.config);
    Call(p.font+55,p.helper);Call(p.coordinates+98,p.helper);
    Put(p.dialogue,na::kDialogue.pattern());
    Call(p.dialogue+94,p.shared);Call(p.dialogue+145,p.entry);
    Put(p.render,na::kRenderEntry.pattern());Call(p.render+18,p.helper);
    Put(p.first,na::kRenderFirstPass.pattern());
    Call(p.first+119,p.shared);Call(p.first+169,p.dialogue);
    Put(p.second,na::kRenderSecondPass.pattern());
    Call(p.second+102,p.shared);Call(p.second+158,p.dialogue);
    Put(p.render_exit,na::kRenderExit.pattern());
    Put(p.group,na::kGroupRender.pattern());
    Put(p.group_owners,na::kGroupOwnerLoop.pattern());
    Call(p.group_owners+96,p.shared);Call(p.group_owners+120,p.render);
    Call(p.group_owners+159,p.helper);
    Put(p.normal,na::kNormalGroups.pattern());
    Call(p.normal+40,p.shared);Call(p.normal+62,p.group);
    Call(p.normal+116,p.shared);Call(p.normal+138,p.group);
    // Legacy text body reached through the message wrapper.
    bytes[p.text]=0x6a;bytes[p.text+1]=0xff;bytes[p.text+2]=0x68;
    Address(p.text+3,p.helper);
    Put(p.text+7,glyph::kTextTail.pattern());Put(p.text+0x100,glyph::kTextString.pattern());
    Put(p.text+0x400,glyph::kTextReturn.pattern());
    Address(p.text+7+14,p.cookie);Address(p.text+7+32,p.cookie);
    Put(p.message,na::kMessage.pattern());
    Address(p.message+3,p.helper);Address(p.message+18,p.cookie);
    Address(p.message+33,p.cookie);Call(p.message+201,p.text);
    Address(p.message+134,p.modal);Address(p.message+149,p.hidden);
    // Input: sampler, message handler, main dispatch, normalize, owner state.
    Put(p.sampler,na::kSampler.pattern());
    Address(p.sampler+25,p.input_slot);Address(p.sampler+47,p.cursor);
    Address(p.sampler+97,p.active);Address(p.sampler+110,p.key);
    for(size_t at:{87u,444u,544u})Call(p.sampler+at,p.helper);
    Put(p.input_message,na::kInputMessage.pattern());
    Address(p.input_message+3,p.input_slot);Address(p.input_message+40,p.table);
    Address(p.input_message+136,p.table+24);
    for(size_t at:{50u,66u,146u,162u,178u,194u,210u,228u})Call(p.input_message+at,p.helper);
    for(size_t i=0;i<std::size(kTable);++i)
      Word(p.table+i*4,static_cast<uint32_t>(base+p.input_message+kTable[i]));
    Put(p.main,input::kMainCall.pattern());Call(p.main+21,p.input_message);
    Put(p.normalize,na::kNormalize.pattern());
    Call(p.normalize+19,p.helper);Call(p.normalize+218,p.helper);
    Call(p.normalize+27,p.sampler);
    for(size_t at:{33u,107u,151u})Address(p.normalize+at,p.input_slot);
    Address(p.normalize+122,p.window);Address(p.normalize+141,p.screen);
    Put(p.design,na::kDesign.pattern());Address(p.design+1,p.config);
    Put(p.owner,na::kOwner.pattern());Address(p.owner+20,p.config);
    Address(p.owner+31,p.owner_a);Address(p.owner+37,p.owner_b);
    Address(p.owner+46,p.manager);
    Put(p.visibility,na::kVisibility.pattern());
    Address(p.visibility+1,p.modal);Address(p.visibility+19,p.auxiliary);
    Address(p.visibility+31,p.hidden);Call(p.visibility+41,p.helper);
    Put(p.gate,na::kInputGate.pattern());Address(p.gate+65,p.hidden);
    Address(p.gate+94,p.config);Call(p.gate+40,p.helper);
  }
  ~Image(){VirtualFree(bytes,0,MEM_RELEASE);}
  Image(const Image&)=delete;
  Image& operator=(const Image&)=delete;
  void Put(uintptr_t at,exact_lookup::MaskedPattern pattern) {
    assert(at+pattern.size<=view.size);std::memcpy(bytes+at,pattern.bytes,pattern.size);
  }
  void Word(uintptr_t at,uint32_t value){std::memcpy(bytes+at,&value,4);}
  void Address(uintptr_t at,uintptr_t rva){Word(at,static_cast<uint32_t>(view.absolute_base+rva));}
  void Call(uintptr_t at,uintptr_t target){bytes[at]=0xe8;Word(at+1,static_cast<uint32_t>(target-at-5));}
  void Check() {
    na::Sites s;assert(na::Resolve(view,&s));++checks;
    assert(s.glyph_entry==p.entry&&s.dialogue_entry==p.dialogue);
    assert(s.dialogue_glyph_return==p.dialogue+150);
    assert(s.render_entry==p.render&&s.group_render==p.group);
    assert(s.text_entry==p.text&&s.message_entry==p.message);
    assert(s.message_text_return==p.message+206);
    assert(s.sampler==p.sampler&&s.key_state_return==p.sampler+117);
    assert(s.key_state_slot==p.key&&s.input_message==p.input_message);
    assert(s.main_message_handler==p.main&&s.main_message_return==p.main+26);
    assert(s.config_slot==p.config&&s.owner_slot==p.manager);
    assert(s.input_slot==p.input_slot&&s.window_slot==p.window);
    assert(s.modal_slot==p.modal&&s.hidden_slot==p.hidden);
    assert(s.auxiliary_slot==p.auxiliary);
  }
  void Reject() {
    na::Sites s;s.glyph_entry=1;s.key_state_slot=2;s.auxiliary_slot=3;
    assert(!na::Resolve(view,&s));++checks;
    assert(!s.glyph_entry&&!s.key_state_slot&&!s.auxiliary_slot&&!s.text_entry);
  }
};

void TestCompleteRelocatedAndMerged() {
  Image{}.Check();
  Image{false,0x65000000}.Check();
  Image{true}.Check();  // A merged section still admits every slot.
  Image{true,0x00400000}.Check();
}
void TestWrongArchitectureAndSpans() {
  Image image;assert(!na::Resolve(image.view,nullptr));
  image.view.machine=IMAGE_FILE_MACHINE_AMD64;image.Reject();
  image.view.machine=IMAGE_FILE_MACHINE_I386;image.view.pointer_bits=64;image.Reject();
  image.view.pointer_bits=32;image.view.sections[0].characteristics=IMAGE_SCN_MEM_READ;
  image.Reject();
  image.view.sections[0].characteristics=IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE;
  image.view.base=nullptr;image.Reject();
}
void TestDuplicateAndDataDecoys() {
  for(const auto pattern : {na::kGlyphEntry.pattern(),na::kGlyphFont.pattern(),
      na::kGlyphCoordinates.pattern(),na::kGlyphReturn.pattern(),na::kDialogue.pattern(),
      na::kRenderEntry.pattern(),na::kRenderFirstPass.pattern(),
      na::kRenderSecondPass.pattern(),na::kRenderExit.pattern(),
      na::kGroupOwnerLoop.pattern(),na::kNormalGroups.pattern(),na::kMessage.pattern(),
      glyph::kTextTail.pattern(),glyph::kTextString.pattern(),glyph::kTextReturn.pattern(),
      na::kSampler.pattern(),na::kInputMessage.pattern(),input::kMainCall.pattern(),
      na::kNormalize.pattern(),na::kDesign.pattern(),na::kOwner.pattern(),
      na::kVisibility.pattern(),na::kInputGate.pattern()}) {
    Image image;image.Put(0x10400,pattern);image.Check(); // Data bytes cannot admit code.
    image.Put(0x8000,pattern);image.Reject(); // An orphaned second anchor is ambiguous.
  }
}
void TestBrokenCallRelationships() {
  for(unsigned n=0;n<23;++n) {
    Image image;const auto& p=image.p;
    switch(n) {
      case 0:image.Call(p.dialogue+145,p.helper);break;
      case 1:image.Call(p.first+169,p.helper);break;
      case 2:image.Call(p.second+158,p.helper);break;
      case 3:image.Call(p.group_owners+120,p.helper);break;
      case 4:image.Call(p.normal+62,p.helper);break;  // Group not reached.
      case 5:image.Call(p.normal+138,p.helper);break;
      case 6:image.Call(p.first+119,p.other);break;   // Shared bounds helper split.
      case 7:image.Call(p.normal+116,p.other);break;
      case 8:image.Call(p.message+201,p.helper);break;
      case 9:image.Call(p.main+21,p.helper);break;
      case 10:image.Call(p.normalize+27,p.helper);break;
      case 11:image.Call(p.input_message+178,p.other);break;  // Paired helpers.
      case 12:image.Call(p.input_message+194,p.other);break;
      case 13:image.Call(p.normalize+218,p.other);break;
      case 14:image.Call(p.font+55,0xffff0000);break;
      case 15:image.Call(p.sampler+444,p.cookie);break;     // Edge leaves code.
      case 16:image.Call(p.visibility+41,p.cookie);break;
      case 17:image.bytes[p.gate+40]=0x90;break;
      case 18:image.Call(p.render+18,p.cookie);break;
      case 19:image.Call(p.group_owners+159,p.cookie);break;
      case 20:image.Call(p.coordinates+98,p.cookie);break;
      case 21:image.Call(p.input_message+228,p.cookie);break;
      case 22:image.Call(p.group_owners+96,p.other);break;
    }
    image.Reject();
  }
}
void TestBodyOrderAndEpilogue() {
  {Image image;image.Word(image.p.entry+58,0);image.Reject();}
  {Image image;image.Put(0x6500,na::kGlyphReturn.pattern());
    std::memset(image.bytes+image.p.glyph_return,0xcc,na::kGlyphReturn.bytes.size());
    image.Word(image.p.entry+58,static_cast<uint32_t>(0x6500-image.p.entry-62));
    image.Reject();}  // A distant epilogue is not the same body.
  {Image image;image.Put(0x1180,na::kGlyphFont.pattern());
    std::memset(image.bytes+image.p.font,0xcc,na::kGlyphFont.bytes.size());
    image.Call(0x1180+55,image.p.helper);image.Reject();}  // Font after coordinates.
  {Image image;const auto& p=image.p;
    // Render passes out of order: swap the second pass ahead of the first.
    std::memset(image.bytes+p.first,0xcc,0x100);std::memset(image.bytes+p.second,0xcc,0x100);
    image.Put(p.first,na::kRenderSecondPass.pattern());
    image.Call(p.first+102,p.shared);image.Call(p.first+158,p.dialogue);
    image.Put(p.second,na::kRenderFirstPass.pattern());
    image.Call(p.second+119,p.shared);image.Call(p.second+169,p.dialogue);
    image.Reject();}
  {Image image;image.bytes[image.p.group]^=1;image.Reject();}  // Group not matched in place.
}
void TestSlotsAndCookies() {
  for(unsigned n=0;n<19;++n) {
    Image image;const auto& p=image.p;
    switch(n) {
      case 0:image.Address(p.entry+25,p.cookie+4);break;
      case 1:image.Address(p.text+7+14,p.cookie+4);break;
      case 2:image.Address(p.message+33,p.cookie+4);break;
      case 3:image.Address(p.entry+3,p.cookie);break;  // Exception scope is code.
      case 4:image.Address(p.message+3,p.cookie);break;
      case 5:image.Address(p.input_message+3,p.window);break;
      case 6:image.Address(p.normalize+107,p.window);break;
      case 7:image.Address(p.owner+20,p.manager);break;
      case 8:image.Address(p.gate+65,p.modal);break;
      case 9:image.Address(p.gate+94,p.manager);break;
      case 10:image.Address(p.coordinates+11,p.manager);break;
      case 11:image.Address(p.message+134,p.hidden);break;
      case 12:image.Address(p.message+149,p.modal);break;
      case 13:image.Address(p.sampler+110,p.cursor);break;  // Distinct pointer slots.
      case 14:image.Address(p.sampler+97,p.cursor);break;
      case 15:image.Address(p.design+1,p.config+2);break;   // Misaligned.
      case 16:image.Word(p.owner+46,0x10);break;              // Outside the image.
      case 17:image.Address(p.owner+31,p.config+1);break;
      case 18:image.Address(p.normalize+141,p.screen+kSize);break;
    }
    image.Reject();
  }
}
void TestJumpTable() {
  for(unsigned n=0;n<4;++n) {
    Image image;const auto& p=image.p;
    switch(n) {
      case 0:image.Address(p.table+8,p.input_message+0xea);break;
      case 1:image.Address(p.input_message+136,p.table+28);break;
      case 2:image.Address(p.table+14*4,p.normalize+0xdc);break;  // Borrowed target.
      case 3:image.Address(p.input_message+40,kSize-8);break;      // Truncated table.
    }
    image.Reject();
  }
}
void TestLegacyTextPrologue() {
  Image image;image.bytes[image.p.text]=0xe9;
  image.Word(image.p.text+1,static_cast<uint32_t>(0x200000-image.p.text-5));
  image.Check();  // An external Luna detour keeps the original body.
  image.Word(image.p.text+1,static_cast<uint32_t>(image.p.helper-image.p.text-5));
  image.Reject();
}
}  // namespace

int main() {
  TestCompleteRelocatedAndMerged();TestWrongArchitectureAndSpans();
  TestDuplicateAndDataDecoys();TestBrokenCallRelationships();
  TestBodyOrderAndEpilogue();TestSlotsAndCookies();TestJumpTable();
  TestLegacyTextPrologue();
  std::printf("Siglus nine-argument family: %u checks passed\n",checks);
  return 0;
}

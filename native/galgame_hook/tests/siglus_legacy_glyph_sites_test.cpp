#include <windows.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdio>
#include "siglus_legacy_glyph_sites.h"

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_legacy_glyph;
struct Layout {
  uintptr_t glyph=0x1000, dialogue=0x2200, text=0x3000;
  uintptr_t bridge=0x4100, writer=0x4800, owner=0x5000;
  uintptr_t helper=0x6000, font=0x6100, assignment=0x6200;
  uintptr_t cookie=0x7800, scalar=0x7900;
};
struct Image {
  uint8_t* bytes=static_cast<uint8_t*>(VirtualAlloc(
      nullptr,0x9000,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  Layout p;
  explicit Image(Layout layout={},uintptr_t base=0x110000) : p(layout) {
    assert(bytes);std::memset(bytes,0xcc,0x9000);
    view.base=bytes;view.absolute_base=base;view.size=0x9000;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;view.section_count=2;
    view.sections[0]={bytes+0x1000,0x6000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes+0x7000,0x2000,0x7000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    Put(p.glyph,kGlyphEntry.pattern());Put(p.glyph+0x100,kGlyphFont.pattern());
    Put(p.glyph+0x200,kGlyphCoordinates.pattern());
    Put(p.glyph+0x300,kGlyphFontSecond.pattern());Put(p.glyph+0x900,kGlyphReturn.pattern());
    Address(p.glyph+3,p.helper);Address(p.glyph+22,p.cookie);
    Address(p.glyph+0x200+68,p.scalar);
    Word(p.glyph+49,static_cast<uint32_t>(p.glyph+0x900-p.glyph-53));
    Call(p.glyph+0x100+52,p.font);Call(p.glyph+0x300+34,p.font);
    Call(p.glyph+0x300+8,p.helper);
    Put(p.dialogue,kDialogueEntry.pattern());Put(p.dialogue+0x50,kDialogueLoop.pattern());
    Call(p.dialogue+0x50+43,p.helper);Call(p.dialogue+0x50+130,p.glyph);
    bytes[p.text]=0x6a;bytes[p.text+1]=0xff;bytes[p.text+2]=0x68;
    Address(p.text+3,p.helper);
    Put(p.text+7,kTextTail.pattern());Put(p.text+0x100,kTextString.pattern());
    Put(p.text+0x800,kTextReturn.pattern());
    Address(p.text+7+14,p.cookie);Address(p.text+7+32,p.cookie);
    Call(p.text+7+98,p.helper);Call(p.text+0x800+14,p.assignment);
    Call(p.text+0x800+37,p.helper);Call(p.text+0x800+73,p.helper);
    Put(p.bridge,kTextBridge.pattern());Call(p.bridge+32,p.text);Call(p.bridge+42,p.writer);
    Put(p.writer,kTextWriter.pattern());Call(p.writer+89,p.helper);Call(p.writer+121,p.assignment);
    Put(p.owner,kOwnerLoopHead.pattern());Put(p.owner+0xc2,kOwnerRender.pattern());
    Call(p.owner+0xc2+84,p.dialogue);
    bytes[p.helper]=0xc3;bytes[p.font]=0xc3;bytes[p.assignment]=0xc3;
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
    LegacyGlyphSites sites;
    assert(ResolveSiglusLegacyGlyphSites(view,&sites));
    assert(sites.glyph_entry_rva==p.glyph);
    assert(sites.dialogue_entry_rva==p.dialogue);
    assert(sites.dialogue_glyph_return_rva==p.dialogue+0x50+135);
    assert(sites.text_entry_rva==p.text && sites.text_bridge_return_rva==p.bridge+37);
    assert(sites.text_writer_rva==p.writer && sites.owner_render_rva==p.owner+0xc2);
  }
  void Reject() {
    LegacyGlyphSites sites{1,2,3,4,5,6,7};
    assert(!ResolveSiglusLegacyGlyphSites(view,&sites));
    assert(!sites.glyph_entry_rva && !sites.dialogue_entry_rva &&
        !sites.dialogue_glyph_return_rva && !sites.text_entry_rva &&
        !sites.text_bridge_return_rva && !sites.text_writer_rva && !sites.owner_render_rva);
  }
};
void TestCompleteRelocatedFamily() {
  Image{}.Check();
  Layout moved;moved.glyph+=0x35;moved.dialogue+=0x81;moved.text+=0x127;
  moved.bridge+=0x42;moved.writer+=0x79;moved.owner+=0x97;
  moved.helper+=0x24;moved.font+=0x18;moved.assignment+=0x15;
  moved.cookie+=0x44;moved.scalar+=0x28;
  Image{moved,0x65000000}.Check();
}
void TestWrongArchitectureAndSpans() {
  Image image;assert(!ResolveSiglusLegacyGlyphSites(image.view,nullptr));
  image.view.machine=IMAGE_FILE_MACHINE_AMD64;image.Reject();
  image.view.machine=IMAGE_FILE_MACHINE_I386;image.view.pointer_bits=64;image.Reject();
  image.view.pointer_bits=32;image.view.sections[0].characteristics=IMAGE_SCN_MEM_READ;image.Reject();
  image.view.sections[0].characteristics=IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE;
  image.view.sections[0].size=0x4800;image.Reject();
  image.view.base=nullptr;image.Reject();
}
void TestDuplicateAndDataDecoys() {
  for(const auto pattern : {kGlyphEntry.pattern(),kGlyphReturn.pattern(),kGlyphFont.pattern(),
      kGlyphFontSecond.pattern(),kGlyphCoordinates.pattern(),kDialogueEntry.pattern(),
      kDialogueLoop.pattern(),kTextTail.pattern(),kTextString.pattern(),kTextReturn.pattern(),
      kTextBridge.pattern(),kTextWriter.pattern(),kOwnerLoopHead.pattern(),kOwnerRender.pattern()}) {
    Image image;image.Put(0x8100,pattern);image.Check(); // Data bytes cannot admit code.
    image.Put(0x6600,pattern);image.Reject(); // Even an orphaned second anchor is ambiguous.
  }
}
void TestBrokenCallRelationships() {
  for(unsigned n=0;n<10;++n) {
    Image image;const auto& p=image.p;
    switch(n) {
      case 0:image.Call(p.dialogue+0x50+130,p.helper);break;
      case 1:image.Call(p.owner+0xc2+84,p.helper);break;
      case 2:image.Call(p.bridge+32,p.helper);break;
      case 3:image.Call(p.bridge+42,p.helper);break;
      case 4:image.Call(p.writer+121,p.helper);break;
      case 5:image.Call(p.glyph+0x300+34,p.helper);break;
      case 6:image.Call(p.glyph+0x100+52,p.cookie);image.Call(p.glyph+0x300+34,p.cookie);break;
      case 7:image.Call(p.text+0x800+14,p.cookie);image.Call(p.writer+121,p.cookie);break;
      case 8:image.Call(p.text+7+98,0xffff0000);break;
      case 9:image.Call(p.writer+89,p.cookie);break;
    }
    image.Reject();
  }
}
void TestAbiAndGeometryMutations() {
  // Each point changes a contract proved by the real instruction's dataflow:
  // stack self, stack cleanup, glyph stride, coordinates, iterator-string
  // buffer/length/capacity, owner vector/stride, and copied-string field.
  for(unsigned n=0;n<13;++n) {
    Image image;const auto& p=image.p;
    const uintptr_t at[]={p.glyph+42,p.glyph+0x900+22,
      p.dialogue+0x50+148,p.glyph+0x200+47,p.glyph+0x200+89,
      p.text+0x100+6,p.text+0x100+13,p.text+0x100+24,
      p.writer+3,p.writer+14,p.writer+99,p.writer+116,p.owner+0xc2+103};
    image.bytes[at[n]]^=1;image.Reject();
  }
  Image image;image.Word(image.p.glyph+49,0);image.Reject();
}
void TestAddressRolesAndCookies() {
  for(unsigned n=0;n<5;++n) {
    Image image;const auto& p=image.p;
    switch(n) {
      case 0:image.Address(p.glyph+3,p.cookie);break;
      case 1:image.Address(p.glyph+22,p.helper);break;
      case 2:image.Address(p.glyph+0x200+68,p.helper);break;
      case 3:image.Address(p.text+7+14,p.cookie+4);break;
      case 4:image.Address(p.text+7+32,p.cookie+4);break;
    }
    image.Reject();
  }
}
void TestOriginalAndLunaDetour() {
  Image image;image.bytes[image.p.text]=0xe9;
  image.Word(image.p.text+1,static_cast<uint32_t>(0x200000-image.p.text-5));image.Check();
  image.Word(image.p.text+1,static_cast<uint32_t>(image.p.helper-image.p.text-5));image.Reject();
  image.bytes[image.p.text]=0x90;image.Reject();
}
void TestSeparatedBodyAndMixedLayout() {
  Image image;
  image.Put(0x6500,kGlyphReturn.pattern());
  std::memset(image.bytes+image.p.glyph+0x900,0xcc,kGlyphReturn.bytes.size());
  image.Word(image.p.glyph+49,static_cast<uint32_t>(0x6500-image.p.glyph-53));
  image.Reject(); // Correct-looking distant epilogue is not the same function.
  Image mixed;
  mixed.Put(mixed.p.glyph,siglus_exact::kGlyphLayoutEntryPattern);
  mixed.Reject(); // The old stack caller cannot bind the modern ECX glyph ABI.
}
}
int main() {
  TestCompleteRelocatedFamily();TestWrongArchitectureAndSpans();
  TestDuplicateAndDataDecoys();TestBrokenCallRelationships();
  TestAbiAndGeometryMutations();TestAddressRolesAndCookies();
  TestOriginalAndLunaDetour();TestSeparatedBodyAndMixedLayout();
  std::puts("8 legacy Siglus glyph-site test groups passed");
}

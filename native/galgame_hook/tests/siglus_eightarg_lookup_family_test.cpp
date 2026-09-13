#undef NDEBUG
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "siglus_eightarg_lookup_family.h"

// Reuse the complete joined PE fixture, not fake resolver return values. Its
// standalone main is namespaced and never invoked by this target.
namespace fixtures {
#include "siglus_eightarg_owner_profile_test.cpp"
}
namespace {
namespace f = fushi_voice_hook::siglus_eightarg_lookup_family;
namespace ex = fushi_voice_hook::exact_lookup;
unsigned checks = 0;
void Empty(const f::Sites& sites) {
  assert(sites.glyph.glyph_entry_rva==0&&sites.glyph.manager_slot_rva==0);
  assert(sites.input.root_slot==0&&sites.input.scene_slot==0);
  assert(sites.owner.engine_owner_slot==0&&sites.owner.normal_case_rva==0);
}
void Pass(fixtures::Fixture& fixture) {
  f::Sites sites;assert(f::Resolve(fixture.image,fixture.imports,&sites));++checks;
  assert(sites.glyph.glyph_entry_rva==fixture.glyph.glyph_entry_rva);
  assert(sites.input.scene_slot==fixture.input.scene_slot);
  assert(sites.owner.normal_render_return_rva==fixture.normal_render+53);
  assert(sites.owner.engine_owner_slot==sites.input.owner_slot);
  assert(sites.owner.scene_slot==sites.input.scene_slot);
  assert(sites.owner.manager_slot==sites.input.manager_slot);
  assert(sites.glyph.config_slot_rva==sites.input.config_slot);
  assert(sites.glyph.render_group_entry_rva==sites.owner.render_group_entry_rva);
  assert(f::ValidateLiveEntries(fixture.image,sites));
}
void Reject(fixtures::Fixture& fixture) {
  f::Sites sites;sites.glyph.glyph_entry_rva=42;sites.input.scene_slot=42;
  sites.owner.normal_case_rva=42;
  assert(!f::Resolve(fixture.image,fixture.imports,&sites));Empty(sites);++checks;
}

// A real low-address mapped PE32 tests OpenSiglusLoadedImage in an x64 test
// process too. Only this test allocation is writable/executable; no process,
// game, loader, imported function or production hook is invoked.
struct Live {
  uint8_t* allocation = nullptr;
  fushi_voice_hook::siglus_eightarg_input_viewport::Imports imports{};
  uintptr_t glyph_entry=0,message_entry=0,scenario_entry=0,sampler=0,input_message=0;
  Live() {
    for(uintptr_t candidate=0x10000000;candidate<0x70000000&&!allocation;candidate+=0x1000000)
      allocation=static_cast<uint8_t*>(VirtualAlloc(reinterpret_cast<void*>(candidate),
          0x24000,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE));
    assert(allocation);
    fixtures::Fixture fixture(false,static_cast<uint32_t>(reinterpret_cast<uintptr_t>(allocation)));
    std::memcpy(allocation,fixture.bytes.data(),fixture.bytes.size());
    imports=fixture.imports;glyph_entry=fixture.glyph.glyph_entry_rva;
    message_entry=fixture.glyph.message_entry_rva;scenario_entry=fixture.glyph.scenario_entry_rva;
    sampler=fixture.input.sampler;input_message=fixture.input.message;
    auto* dos=reinterpret_cast<IMAGE_DOS_HEADER*>(allocation);
    *dos={};dos->e_magic=IMAGE_DOS_SIGNATURE;dos->e_lfanew=0x80;
    auto* nt=reinterpret_cast<IMAGE_NT_HEADERS32*>(allocation+0x80);
    *nt={};nt->Signature=IMAGE_NT_SIGNATURE;nt->FileHeader.Machine=IMAGE_FILE_MACHINE_I386;
    nt->FileHeader.SizeOfOptionalHeader=sizeof(IMAGE_OPTIONAL_HEADER32);
    nt->FileHeader.NumberOfSections=static_cast<WORD>(fixture.image.section_count);
    nt->OptionalHeader.Magic=IMAGE_NT_OPTIONAL_HDR32_MAGIC;
    nt->OptionalHeader.SizeOfImage=static_cast<DWORD>(fixture.image.size);
    nt->OptionalHeader.ImageBase=static_cast<DWORD>(reinterpret_cast<uintptr_t>(allocation));
    auto* sections=IMAGE_FIRST_SECTION(nt);
    for(size_t n=0;n<fixture.image.section_count;++n){sections[n]={};
      sections[n].VirtualAddress=fixture.image.sections[n].rva;
      sections[n].Misc.VirtualSize=static_cast<DWORD>(fixture.image.sections[n].size);
      // Deliberately impossible raw payload extent: live Siglus uses VirtualSize.
      sections[n].SizeOfRawData=0xffffffff;
      sections[n].Characteristics=fixture.image.sections[n].characteristics;
    }
  }
  ~Live(){if(allocation)VirtualFree(allocation,0,MEM_RELEASE);}
  HMODULE module()const{return reinterpret_cast<HMODULE>(allocation);}
  void Pass(){f::Sites sites;assert(f::ResolveLive(module(),imports,&sites));++checks;
    assert(sites.glyph.glyph_entry_rva==glyph_entry&&sites.input.sampler==sampler);}
  void Reject(){f::Sites sites;sites.glyph.glyph_entry_rva=42;sites.input.scene_slot=42;
    assert(!f::ResolveLive(module(),imports,&sites));Empty(sites);++checks;}
};
}
int main(){
  {fixtures::Fixture fixture;Pass(fixture);}
  {fixtures::Fixture fixture(true,0x240000);Pass(fixture);}
  for(unsigned n=0;n<12;++n){fixtures::Fixture fixture;switch(n){
    case 0:fixture.bytes[fixture.glyph_entry]=0xe9;break;
    case 1:fixture.bytes[fixture.scenario]=0xe9;break;
    case 2:fixture.bytes[fixture.message]=0xe9;break;
    case 3:fixture.bytes[fixture.input.sampler]=0xe9;break;
    case 4:fixture.bytes[fixture.input.message]=0xe9;break;
    case 5:fixture.imports.key_state=0;break;
    case 6:fixture.imports.cursor_position=fixture.imports.active_window;break;
    case 7:fixture.Abs(fixture.normal+9,fixture.input.scene_slot+4);break;
    case 8:fixture.Rel(fixture.group+131,fixture.element+1);break;
    case 9:fixture.WordAt(fixture.normal+21,0xe68);break;
    case 10:fixture.Put(0x1c000,fushi_voice_hook::siglus_eight_arg_glyph::kWrapper.pattern());break;
    case 11:fixture.image.pointer_bits=64;break;
  }
    if(n==7||n==8||n==9){
      fushi_voice_hook::SiglusEightArgGlyphSites glyph;
      fushi_voice_hook::siglus_eightarg_input_viewport::Sites input;
      assert(fushi_voice_hook::siglus_eight_arg_glyph::Resolve(fixture.image,&glyph));
      assert(fushi_voice_hook::siglus_eightarg_input_viewport::Resolve(
          fixture.image,fixture.imports,&input));
    }
    Reject(fixture);
  }
  // Exact final-entry validation also rejects stale or out-of-range Site maps.
  {fixtures::Fixture fixture;f::Sites sites;assert(f::Resolve(fixture.image,fixture.imports,&sites));
    uintptr_t* entries[]={&sites.glyph.glyph_entry_rva,&sites.glyph.message_entry_rva,
      &sites.glyph.scenario_entry_rva,&sites.input.sampler,&sites.input.message};
    for(auto entry:entries){const auto saved=*entry;for(auto bad:{uintptr_t(0),fixture.image.size}){
      *entry=bad;assert(!f::ValidateLiveEntries(fixture.image,sites));++checks;}*entry=saved;}
  }
  {Live live;live.Pass();const uintptr_t entries[]={live.glyph_entry,live.message_entry,
      live.scenario_entry,live.sampler,live.input_message};
    for(auto entry:entries){const auto old=live.allocation[entry];live.allocation[entry]=0xe9;
      live.Reject();live.allocation[entry]=old;}live.Pass();
    auto* nt=reinterpret_cast<IMAGE_NT_HEADERS32*>(live.allocation+0x80);
    nt->FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;live.Reject();
    nt->FileHeader.Machine=IMAGE_FILE_MACHINE_I386;
    auto* section=IMAGE_FIRST_SECTION(nt);section[1].VirtualAddress=section[0].VirtualAddress;
    live.Reject();
  }
  {f::Sites sites;sites.owner.normal_case_rva=42;assert(!f::ResolveLive(nullptr,{},&sites));
    Empty(sites);assert(!f::ResolveLive(nullptr,{},nullptr));++checks;}
  {fixtures::Fixture fixture;assert(!f::Resolve(fixture.image,fixture.imports,nullptr));++checks;}
  std::printf("Siglus eight-argument lookup family: %u checks passed\n",checks);
  return 0;
}

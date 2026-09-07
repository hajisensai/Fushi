// SPDX-License-Identifier: LGPL-3.0-or-later
// Process-local locale emulation. Never return borrowed TLS resource storage.
#include "version_resource_locale.h"

BOOL WINAPI LeGetFileVersionInfoW(LPCWSTR name, DWORD handle, DWORD size,
                                LPVOID data)
{
    PLeGlobalData global = LeGetGlobalData();
    BOOL result = global->HookStub.StubGetFileVersionInfoW(name, handle, size, data);
    if (result && data != nullptr)
    {
        fushi_locale_emulator::CopyVersionResourceWithLocale(
            data, size, data, size, (unsigned short)global->GetLeb()->LocaleID);
    }
    return result;
}

BOOL WINAPI LeGetFileVersionInfoExW(DWORD flags, LPCWSTR name, DWORD handle,
                                  DWORD size, LPVOID data)
{
    PLeGlobalData global = LeGetGlobalData();
    BOOL result = global->HookStub.StubGetFileVersionInfoExW(
        flags, name, handle, size, data);
    if (result && data != nullptr)
    {
        fushi_locale_emulator::CopyVersionResourceWithLocale(
            data, size, data, size, (unsigned short)global->GetLeb()->LocaleID);
    }
    return result;
}

NTSTATUS LeGlobalData::HookVersionRoutines(PVOID version)
{
    PVOID basic = LookupExportTable(version, "GetFileVersionInfoW");
    PVOID extended = LookupExportTable(version, "GetFileVersionInfoExW");
    if (basic == nullptr || extended == nullptr)
        return STATUS_PROCEDURE_NOT_FOUND;
    if (HookStub.StubGetFileVersionInfoW != nullptr &&
        HookStub.StubGetFileVersionInfoExW != nullptr)
        return STATUS_SUCCESS;
    NTSTATUS cleanup = UnHookVersionRoutines();
    if (NT_FAILED(cleanup))
        return cleanup;
    // Inline jumps and their trampolines must outlive dynamic FreeLibrary calls.
    // Both modules become process-lifetime dependencies before installing a jump.
    // SelfShadow is private process-owned memory and never a loader module.
    // Normal DllMain entry still requires a successful loader pin.
    if (!ProcessOwnedMapping)
    {
        NTSTATUS pinned = LdrAddRefDll(LDR_ADDREF_DLL_PIN, &__ImageBase);
        if (NT_FAILED(pinned))
            return pinned;
    }
    NTSTATUS pinned = LdrAddRefDll(LDR_ADDREF_DLL_PIN, version);
    if (NT_FAILED(pinned))
        return pinned;
    Mp::PATCH_MEMORY_DATA patches[] =
    {
        Mp::FunctionJumpVa(basic, LeGetFileVersionInfoW,
                           &HookStub.StubGetFileVersionInfoW),
        Mp::FunctionJumpVa(extended, LeGetFileVersionInfoExW,
                           &HookStub.StubGetFileVersionInfoExW),
    };
    NTSTATUS status = Mp::PatchMemory(patches, countof(patches));
    if (NT_FAILED(status))
    {
        cleanup = UnHookVersionRoutines();
        if (NT_FAILED(cleanup))
            return cleanup;
    }
    return status;
}

NTSTATUS LeGlobalData::UnHookVersionRoutines()
{
    // RestoreMemory clears each reference only after successful restoration.
    // Preserve a failed trampoline so cleanup remains possible.
    NTSTATUS basic = Mp::RestoreMemory(HookStub.StubGetFileVersionInfoW);
    NTSTATUS extended = Mp::RestoreMemory(HookStub.StubGetFileVersionInfoExW);
    return NT_FAILED(basic) ? basic : extended;
}

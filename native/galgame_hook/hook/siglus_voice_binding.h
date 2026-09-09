#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace fushi_voice_hook::siglus {

constexpr uint32_t kVoiceMemberRadix = 100000;
constexpr uint32_t kNoVoiceKey = UINT32_MAX;
constexpr size_t kVoiceSourcePathCapacity = 520;

enum class VoiceBindingStatus {
  kAccepted,
  kDuplicate,
  kInvalid,
  kPending,
  kReady,
  kConsumed,
  kStaleEvent,
  kAmbiguous,
  kCapacityExceeded,
};

struct VoiceTextEvent {
  uint64_t event_id = 0;  // Actual committed TextSlot sequence, never layout ID.
  uint32_t voice_key = kNoVoiceKey;  // Frozen at the proved script boundary.
  uint64_t text_tick = 0;  // Output metadata only; never a matching criterion.
};

struct VoiceResourceMetadata {
  uint32_t archive_component = 0;
  uint32_t member_id = 0;
  std::wstring source_path;
  uint64_t source_offset = 0;
  uint64_t archive_revision = 0;  // Opaque, nonzero frozen-index identity token.
};

struct VoiceBinding {
  VoiceTextEvent text;
  VoiceResourceMetadata resource;
};

// This arithmetic is opt-in for a profile that proves the composite-key ABI.
// Basename appearance alone does not authorize that profile or classify audio.
inline bool ComposeVoiceKey(uint32_t archive_component, uint32_t member_id,
                            uint32_t* key) {
  if (key == nullptr || member_id >= kVoiceMemberRadix) return false;
  const uint64_t value = static_cast<uint64_t>(archive_component) *
                             kVoiceMemberRadix + member_id;
  if (value >= kNoVoiceKey) return false;
  *key = static_cast<uint32_t>(value);
  return true;
}

// Single-worker state machine; caller serializes every operation and Reset.
// Inputs must come from the same live session and a validated engine profile.
// Resource metadata means an observed, validated OVK member, not a ReadFile
// timestamp, guessed path, or proof that it played with the text. Paths must be
// canonicalized by the caller; different spellings conservatively conflict.
// The worker must freeze file identity (volume/file index, size, last-write)
// and validate an index with a unique member->offset mapping before assigning
// archive_revision. It must reject changed files and validate every resource
// against that frozen index. This is what permits member cache eviction without
// forgetting evidence of an old offset; the helper cannot prove this contract.
// Any observed path/revision/offset conflict permanently poisons its archive.
//
// New events arrive in strictly increasing committed sequence order (gaps from
// other text writers are allowed). Only pending event identities occupy slots;
// the high-water mark rejects already consumed or capacity-rejected sequences.
// Put the default-sized cache in static/heap storage, not a hook thread stack.
template <size_t ResourceCapacity = 128, size_t EventCapacity = 64,
          size_t ArchiveCapacity = 1024>
class VoiceBindingCache {
 public:
  static_assert(ResourceCapacity > 0 && EventCapacity > 0 && ArchiveCapacity > 0,
                "voice binding requires nonzero capacities");

  void Reset() {
    for (auto& resource : resources_) resource = {};
    for (auto& event : events_) event = {};
    for (auto& archive : archives_) archive = {};
    highest_event_id_ = 0;
    resource_clock_ = 0;
  }

  VoiceBindingStatus ObserveText(const VoiceTextEvent& text) {
    if (text.event_id == 0) return VoiceBindingStatus::kInvalid;
    EventRecord* empty = nullptr;
    for (auto& record : events_) {
      if (record.text.event_id == text.event_id) {
        if (record.text.voice_key != text.voice_key ||
            record.text.text_tick != text.text_tick) record.ambiguous = true;
        return record.ambiguous ? VoiceBindingStatus::kAmbiguous
                                : VoiceBindingStatus::kDuplicate;
      }
      if (record.text.event_id == 0 && empty == nullptr) empty = &record;
    }
    if (text.event_id <= highest_event_id_) return VoiceBindingStatus::kStaleEvent;
    highest_event_id_ = text.event_id;
    if (text.voice_key == kNoVoiceKey) return VoiceBindingStatus::kInvalid;
    if (empty == nullptr) return VoiceBindingStatus::kCapacityExceeded;
    empty->text = text;
    return VoiceBindingStatus::kAccepted;
  }

  VoiceBindingStatus ObserveResource(const VoiceResourceMetadata& resource) {
    uint32_t key = 0;
    if (!ComposeVoiceKey(resource.archive_component, resource.member_id, &key) ||
        resource.archive_revision == 0 || resource.source_path.empty() ||
        resource.source_path.size() >= kVoiceSourcePathCapacity ||
        resource.source_path.find(L'\0') != std::wstring::npos)
      return VoiceBindingStatus::kInvalid;
    ArchiveRecord* archive = nullptr;
    ArchiveRecord* empty_archive = nullptr;
    for (auto& record : archives_) {
      if (record.used && record.component == resource.archive_component) {
        archive = &record;
        break;
      }
      if (!record.used && empty_archive == nullptr) empty_archive = &record;
    }
    if (archive != nullptr) {
      if (archive->revision != resource.archive_revision ||
          resource.source_path != archive->path.data()) archive->ambiguous = true;
      if (archive->ambiguous) return VoiceBindingStatus::kAmbiguous;
    } else {
      if (empty_archive == nullptr) return VoiceBindingStatus::kCapacityExceeded;
      archive = empty_archive;
      archive->used = true;
      archive->component = resource.archive_component;
      archive->revision = resource.archive_revision;
      resource.source_path.copy(archive->path.data(), resource.source_path.size());
    }
    ResourceRecord* empty = nullptr;
    ResourceRecord* oldest_unreferenced = nullptr;
    for (auto& record : resources_) {
      if (record.used && record.key == key) {
        if (record.offset != resource.source_offset) {
          archive->ambiguous = true;
          return VoiceBindingStatus::kAmbiguous;
        }
        record.recency = ++resource_clock_;
        return VoiceBindingStatus::kDuplicate;
      }
      if (!record.used && empty == nullptr) empty = &record;
      if (record.used && !HasPendingKey(record.key) &&
          (oldest_unreferenced == nullptr ||
           record.recency < oldest_unreferenced->recency))
        oldest_unreferenced = &record;
    }
    if (empty == nullptr) empty = oldest_unreferenced;
    if (empty == nullptr) return VoiceBindingStatus::kCapacityExceeded;
    empty->used = true;
    empty->key = key;
    empty->offset = resource.source_offset;
    empty->recency = ++resource_clock_;
    return VoiceBindingStatus::kAccepted;
  }

  // A previous returned value is only a snapshot. Query immediately before
  // export on the same worker; later conflicting evidence invalidates future
  // queries but cannot revoke a file already written by the caller.
  VoiceBindingStatus GetBinding(uint64_t event_id, VoiceBinding* out) const {
    if (out != nullptr) *out = {};
    if (event_id == 0 || out == nullptr) return VoiceBindingStatus::kInvalid;
    for (const auto& event : events_) {
      if (event.text.event_id != event_id) continue;
      if (event.ambiguous) return VoiceBindingStatus::kAmbiguous;
      const auto* archive = FindArchive(event.text.voice_key / kVoiceMemberRadix);
      if (archive == nullptr) return VoiceBindingStatus::kPending;
      if (archive->ambiguous) return VoiceBindingStatus::kAmbiguous;
      for (const auto& resource : resources_) {
        if (!resource.used || resource.key != event.text.voice_key) continue;
        out->text = event.text;
        out->resource = {resource.key / kVoiceMemberRadix,
                         resource.key % kVoiceMemberRadix,
                         archive->path.data(), resource.offset,
                         archive->revision};
        return VoiceBindingStatus::kReady;
      }
      return VoiceBindingStatus::kPending;
    }
    return event_id <= highest_event_id_ ? VoiceBindingStatus::kStaleEvent
                                        : VoiceBindingStatus::kPending;
  }

  VoiceBindingStatus NextBinding(VoiceBinding* out) const {
    if (out == nullptr) return VoiceBindingStatus::kInvalid;
    *out = {};
    for (const auto& event : events_) {
      if (event.text.event_id != 0 &&
          GetBinding(event.text.event_id, out) == VoiceBindingStatus::kReady)
        return VoiceBindingStatus::kReady;
    }
    return VoiceBindingStatus::kPending;
  }

  // Consume only after successful export. The high-water mark prevents any
  // later delivery from resurrecting this event with another resource.
  VoiceBindingStatus ConsumeEvent(uint64_t event_id) {
    VoiceBinding binding;
    const auto status = GetBinding(event_id, &binding);
    if (status != VoiceBindingStatus::kReady) return status;
    for (auto& event : events_) {
      if (event.text.event_id == event_id) {
        event = {};
        return VoiceBindingStatus::kConsumed;
      }
    }
    return VoiceBindingStatus::kPending;
  }

  // Explicitly cancel an unexportable/abandoned pending event. Its sequence
  // remains below the high-water mark, including when it was ambiguous.
  bool DiscardEvent(uint64_t event_id) {
    if (event_id == 0) return false;
    for (auto& event : events_) {
      if (event.text.event_id == event_id) {
        event = {};
        return true;
      }
    }
    return false;
  }

 private:
  struct EventRecord {
    VoiceTextEvent text;
    bool ambiguous = false;
  };
  struct ResourceRecord {
    bool used = false;
    uint32_t key = 0;
    uint64_t offset = 0;
    uint64_t recency = 0;
  };
  struct ArchiveRecord {
    bool used = false;
    bool ambiguous = false;
    uint32_t component = 0;
    uint64_t revision = 0;
    std::array<wchar_t, kVoiceSourcePathCapacity> path{};
  };
  bool HasPendingKey(uint32_t key) const {
    for (const auto& event : events_) {
      if (event.text.event_id != 0 && event.text.voice_key == key) return true;
    }
    return false;
  }
  const ArchiveRecord* FindArchive(uint32_t component) const {
    for (const auto& archive : archives_) {
      if (archive.used && archive.component == component) return &archive;
    }
    return nullptr;
  }
  std::array<ResourceRecord, ResourceCapacity> resources_{};
  std::array<EventRecord, EventCapacity> events_{};
  std::array<ArchiveRecord, ArchiveCapacity> archives_{};
  uint64_t highest_event_id_ = 0;
  uint64_t resource_clock_ = 0;
};

}  // namespace fushi_voice_hook::siglus

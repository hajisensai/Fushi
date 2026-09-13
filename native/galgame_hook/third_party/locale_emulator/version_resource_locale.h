// SPDX-License-Identifier: LGPL-3.0-or-later
// Hibiki modification, 2026-09-08. No Windows APIs or thread-local storage.
#pragma once
#include <stddef.h>

namespace fushi_locale_emulator {
namespace version_resource_detail {

struct Block {
  size_t begin, end, key, key_end, value, value_size, children;
  unsigned int type;
};

inline unsigned int Word(const unsigned char* data, size_t offset) {
  return data[offset] | (static_cast<unsigned int>(data[offset + 1]) << 8);
}

inline size_t Align4(size_t value) {
  return (value + 3) & ~static_cast<size_t>(3);
}

inline bool ReadBlock(const unsigned char* data, size_t begin,
                      size_t limit, Block* result) {
  if (begin > limit || limit - begin < 6 || (begin & 3) != 0) return false;
  const size_t length = Word(data, begin);
  const unsigned int value_length = Word(data, begin + 2);
  const unsigned int type = Word(data, begin + 4);
  if (length < 8 || length > limit - begin || type > 1) return false;
  const size_t end = begin + length;
  size_t cursor = begin + 6;
  while (cursor + 2 <= end && Word(data, cursor) != 0) cursor += 2;
  if (cursor + 2 > end) return false;
  const size_t key_end = cursor + 2;
  const size_t value_size = value_length * (type == 1 ? 2u : 1u);
  size_t value = Align4(key_end);
  if (value > end) {
    if (key_end != end || value_size != 0) return false;
    value = end;
  }
  if (value_size > end - value) return false;
  for (size_t padding = key_end; padding < value; ++padding)
    if (data[padding] != 0) return false;
  const size_t value_end = value + value_size;
  size_t children = Align4(value_end);
  if (children > end) {
    if (value_end != end) return false;
    children = end;
  }
  for (size_t padding = value_end; padding < children; ++padding)
    if (data[padding] != 0) return false;
  *result = Block{begin, end, begin + 6, key_end, value, value_size,
                  children, type};
  return true;
}

inline bool KeyIs(const unsigned char* data, const Block& block,
                  const char* expected) {
  size_t position = block.key;
  for (; *expected != '\0'; ++expected, position += 2) {
    if (position + 2 >= block.key_end ||
        Word(data, position) != static_cast<unsigned char>(*expected))
      return false;
  }
  return position + 2 == block.key_end;
}

struct Search {
  bool found_var = false;
  bool found_translation = false;
  bool found_strings = false;
  Block strings{};
  size_t translation_offset = 0;
  size_t translation_size = 0;
};

// Validate every sibling before exposing a writable offset. The depth limit
// exceeds the standard root/StringFileInfo/table/string hierarchy and bounds
// stack use even for adversarial, deeply nested version resources.
inline bool Walk(const unsigned char* data, const Block& parent,
                 unsigned int depth, bool is_var, Search* search) {
  if (depth > 8) return false;
  size_t position = parent.children;
  while (position < parent.end) {
    if (parent.end - position < 6) {
      if (parent.end - position > 3) return false;
      for (; position < parent.end; ++position)
        if (data[position] != 0) return false;
      return true;
    }
    Block child{};
    if (!ReadBlock(data, position, parent.end, &child)) return false;
    const bool child_is_var = depth == 0 && KeyIs(data, child, "VarFileInfo");
    if (depth == 0 && KeyIs(data, child, "StringFileInfo")) {
      if (search->found_strings || child.type != 1 || child.value_size != 0)
        return false;
      search->found_strings = true;
      search->strings = child;
    }
    const bool child_is_translation =
        depth == 1 && is_var && KeyIs(data, child, "Translation");
    if (child_is_var) {
      if (search->found_var || child.type != 1 || child.value_size != 0)
        return false;
      search->found_var = true;
    }
    if (child_is_translation) {
      if (search->found_translation || child.type != 0 ||
          child.value_size < 4 || (child.value_size & 3) != 0 ||
          child.children != child.end)
        return false;
      search->found_translation = true;
      search->translation_offset = child.value;
      search->translation_size = child.value_size;
    }
    if (!Walk(data, child, depth + 1, child_is_var, search)) return false;
    if (child.end == parent.end) return true;
    const size_t next = Align4(child.end);
    if (next > parent.end) return false;
    for (size_t padding = child.end; padding < next; ++padding)
      if (data[padding] != 0) return false;
    position = next;
  }
  return true;
}

inline bool ReadResource(const void* input, size_t input_size, Search* search) {
  if (input == nullptr || input_size < 8) return false;
  const auto* data = static_cast<const unsigned char*>(input);
  Block root{};
  return ReadBlock(data, 0, input_size, &root) && root.type == 0 &&
      KeyIs(data, root, "VS_VERSION_INFO") &&
      (root.value_size == 0 || root.value_size == 52) &&
      Walk(data, root, 0, false, search) && search->found_translation;
}

inline bool TableIdentity(const unsigned char* data, const Block& table,
                           unsigned int* identity) {
  if (table.type != 1 || table.value_size != 0 ||
      table.key_end - table.key != 18) return false;
  unsigned int value = 0;
  for (size_t index = 0; index < 8; ++index) {
    const unsigned int ch = Word(data, table.key + index * 2);
    unsigned int digit;
    if (ch >= '0' && ch <= '9') digit = ch - '0';
    else if (ch >= 'a' && ch <= 'f') digit = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'F') digit = ch - 'A' + 10;
    else return false;
    value = (value << 4) | digit;
  }
  *identity = value;
  return true;
}

// Resolve the matching table and reject ambiguous renames before any writes.
// A later translation must not lose its table or collide with the new pair.
inline bool PlanTableRename(const unsigned char* data, const Search& search,
                            unsigned short language, size_t* table_key) {
  const size_t at = search.translation_offset;
  const unsigned int old_language = Word(data, at);
  const unsigned int codepage = Word(data, at + 2);
  const unsigned int original = (old_language << 16) | codepage;
  const unsigned int replacement = (static_cast<unsigned int>(language) << 16) | codepage;
  if (original != replacement) {
    for (size_t index = 4; index < search.translation_size; index += 4) {
      if (Word(data, at + index + 2) == codepage &&
          (Word(data, at + index) == old_language ||
           Word(data, at + index) == language)) return false;
    }
  }
  if (!search.found_strings) return true;
  bool found = false;
  size_t position = search.strings.children;
  while (position < search.strings.end) {
    if (search.strings.end - position < 6) break; // Walk validated padding.
    Block table{};
    unsigned int identity = 0;
    if (!ReadBlock(data, position, search.strings.end, &table) ||
        !TableIdentity(data, table, &identity)) return false;
    if (identity == original) {
      if (found) return false;
      found = true;
      *table_key = table.key;
    } else if (identity == replacement) {
      return false;
    }
    position = Align4(table.end);
  }
  return found;
}

}  // namespace version_resource_detail

// On failure, leave the caller's offset unchanged. The input is borrowed only
// for this call; no pointer into it is retained. The offset is valid only while
// the caller keeps that same validated resource unchanged.
inline bool FindVersionTranslationOffset(const void* input,
                                         size_t input_size,
                                         size_t* offset) {
  if (offset == nullptr) return false;
  version_resource_detail::Search search;
  if (!version_resource_detail::ReadResource(input, input_size, &search)) return false;
  *offset = search.translation_offset;
  return true;
}

// Copy only after complete validation. For distinct buffers preserve the source;
// an identical source/destination explicitly requests an in-place update of a
// caller-owned buffer. Partial overlap is rejected. Preserve the codepage,
// later translation pairs, and bytes outside the version root in both modes.
// Rename the first pair's StringTable language prefix with the translation;
// reject missing/ambiguous matching tables and destination-key collisions.
inline bool CopyVersionResourceWithLocale(const void* input,
                                          size_t input_size,
                                          void* output,
                                          size_t output_capacity,
                                          unsigned short language) {
  if (input == nullptr || output == nullptr || output_capacity < input_size)
    return false;
  static_assert(sizeof(size_t) >= sizeof(void*), "Windows pointer size");
  const auto from = reinterpret_cast<size_t>(input);
  const auto to = reinterpret_cast<size_t>(output);
  if (to != from && (to >= from ? to - from : from - to) < input_size)
    return false;
  const auto* source = static_cast<const unsigned char*>(input);
  version_resource_detail::Search search;
  size_t table_key = 0;
  if (!version_resource_detail::ReadResource(input, input_size, &search) ||
      !version_resource_detail::PlanTableRename(source, search, language, &table_key))
    return false;
  const size_t offset = search.translation_offset;
  const bool rename_table = table_key != 0 &&
      version_resource_detail::Word(source, offset) != language;
  auto* target = static_cast<unsigned char*>(output);
  if (to != from) {
    for (size_t index = 0; index < input_size; ++index)
      target[index] = source[index];
  }
  target[offset] = static_cast<unsigned char>(language);
  target[offset + 1] = static_cast<unsigned char>(language >> 8);
  if (rename_table) {
    const char* digits = "0123456789abcdef";
    for (size_t index = 0; index < 4; ++index) {
      target[table_key + index * 2] = static_cast<unsigned char>(
          digits[(language >> ((3 - index) * 4)) & 15]);
    }
  }
  return true;
}

}  // namespace fushi_locale_emulator

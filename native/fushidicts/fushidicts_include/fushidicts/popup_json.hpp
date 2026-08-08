#pragma once

#include <string>
#include <vector>

#include "lookup.hpp"
#include "query.hpp"

std::string build_popup_json(const std::vector<LookupResult>& results,
                             int max_terms);

std::string build_styles_json(DictionaryQuery& query);

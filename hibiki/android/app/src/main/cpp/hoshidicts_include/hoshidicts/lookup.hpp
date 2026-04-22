#pragma once

#include <string>
#include <vector>

#include "deinflector.hpp"
#include "query.hpp"

struct LookupResult {
  std::string matched;
  std::string deinflected;
  std::vector<TransformGroup> trace;
  TermResult term;
  int preprocessor_steps;
};

class Lookup {
 public:
  Lookup(DictionaryQuery& query, Deinflector& deinflector) : query_(query), deinflector_(deinflector) {};
  std::vector<LookupResult> lookup(const std::string& lookup_string, int max_results = 16,
                                   size_t scan_length = 16) const;

 private:
  static void filter_by_pos(std::vector<TermResult>& terms, const DeinflectionResult& d);

  DictionaryQuery& query_;
  Deinflector& deinflector_;
};
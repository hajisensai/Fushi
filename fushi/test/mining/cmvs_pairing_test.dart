import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cmvs fixture stays explicitly unverified until evidence is added',
    () async {
      final data =
          jsonDecode(
                await File(
                  'test/fixtures/galhook/cmvs_replay.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(data['status'], 'implemented_unverified');
    },
  );
}

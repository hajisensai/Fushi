import 'package:flutter_test/flutter_test.dart';

import 'fake_asset_store.dart';
import 'sync_asset_store_contract.dart';

void main() {
  runAssetStoreContract('FakeAssetStore', FakeAssetStore.new);
}

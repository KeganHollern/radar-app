import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/services/lightning_visibility_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'lightning visibility defaults off and persists explicit opt-in',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesLightningVisibilityStore();

      expect(await store.load(), isFalse);
      await store.save(true);
      expect(await store.load(), isTrue);
      await store.save(false);
      expect(await store.load(), isFalse);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/src/data/storage_privacy.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native library backup exclusions can be applied and verified', (
    tester,
  ) async {
    // The iOS method returns true only after reading both directory attributes
    // back. Repeating the operation must also work for an existing library.
    await preparePrivateStorage();
    await preparePrivateStorage();
  });
}

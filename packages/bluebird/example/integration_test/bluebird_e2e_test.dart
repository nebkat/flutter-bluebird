// Host-app runner: plugin integration tests must execute inside an app, so
// this forwards to the canonical suite in the package's integration_test/.
import '../../integration_test/bluebird_e2e_test.dart' as suite;

void main() => suite.main();

import 'package:rig_mysql/src/mysql_auth.dart';
import 'package:test/test.dart';

void main() {
  test('caching_sha2 needs nothing from the server beyond its default', () {
    final setup = setupFor(MySqlAuth.cachingSha2);

    expect(setup.plugin, 'caching_sha2_password');
    expect(setup.serverFlags, isEmpty);
  });

  test('native password asks for the plugin to be loaded', () {
    final setup = setupFor(MySqlAuth.nativePassword);

    expect(setup.plugin, 'mysql_native_password');
    expect(setup.serverFlags, ['--loose-mysql-native-password=ON']);
  });

  test('the native password flag keeps its loose prefix', () {
    // 8.4 does not load mysql_native_password unless told to, and the option
    // that tells it does not exist in 8.0 — passing it there stops the
    // server from starting at all. The loose prefix turns an unknown option
    // into a warning, so one spelling serves both versions. Dropping it
    // would break 8.0 and nothing else here would notice.
    expect(
      setupFor(MySqlAuth.nativePassword).serverFlags.single,
      startsWith('--loose-'),
    );
  });

  test('every auth mode has a setup', () {
    // A switch over the enum is exhaustive at compile time, but a mode added
    // with an empty plugin name would pass that and fail at runtime against
    // a real server.
    for (final auth in MySqlAuth.values) {
      expect(setupFor(auth).plugin, isNotEmpty, reason: '$auth');
    }
  });
}

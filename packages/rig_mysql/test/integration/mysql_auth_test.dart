@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

Future<String> storedPluginOf(MySqlLease my) async {
  final engine = await currentEngine();
  final result = await engine.exec(my.container.containerId, [
    'mysql',
    '-uroot',
    '-p${my.rootPassword}',
    '-N',
    '-B',
    '-e',
    "SELECT plugin FROM mysql.user WHERE user = '${my.user}'",
  ]);
  expect(result.exitCode, 0, reason: result.output);
  return result.output.trim();
}

void main() {
  group('8.4', () {
    group('caching_sha2', () {
      final my = useMySql(version: '8.4', isolation: MySqlIsolation.none);

      test('is what the password is actually stored under', () async {
        expect(await storedPluginOf(my), 'caching_sha2_password');
      });
    });

    group('native password', () {
      final my = useMySql(
        version: '8.4',
        auth: MySqlAuth.nativePassword,
        isolation: MySqlIsolation.none,
      );

      test('is loaded and is what the password is stored under', () async {
        // 8.4 does not load this plugin unless asked. If the loose- prefixed
        // flag did not reach the server, the ALTER USER in setUpAll would
        // have failed and this suite would never have got here — so
        // reaching this line at all is half the assertion.
        expect(await storedPluginOf(my), 'mysql_native_password');
      });
    });
  });

  group('8.0', () {
    group('caching_sha2', () {
      final my = useMySql(version: '8.0', isolation: MySqlIsolation.none);

      test('is what the password is actually stored under', () async {
        expect(await storedPluginOf(my), 'caching_sha2_password');
      });
    });

    group('native password', () {
      final my = useMySql(
        version: '8.0',
        auth: MySqlAuth.nativePassword,
        isolation: MySqlIsolation.none,
      );

      test('works even though the enabling flag does not exist here', () async {
        // --mysql-native-password does not exist in 8.0. The loose- prefix
        // is what keeps passing it from stopping this server from starting,
        // so a healthy container is itself the assertion.
        expect(await storedPluginOf(my), 'mysql_native_password');
      });
    });
  });
}

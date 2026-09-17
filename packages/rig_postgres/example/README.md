# Example

The runnable example lives at [examples/basic-sample](../../../examples/basic-sample)
in this repository, as two test files. This package is a library your *tests*
use, so an example that is not a test would misrepresent it — and keeping it
there means continuous integration runs it on every push.

```dart
import 'dart:io';

import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  // `auth:` is the reason this package exists. Asking for md5 here gives a
  // server that really stores an md5 verifier — set the method without
  // re-hashing the password and Postgres quietly keeps using SCRAM, so a test
  // that believes it exercises md5 exercises nothing.
  final pg = usePostgres(auth: PgAuth.md5);

  test('the suite gets a URL and a database of its own', () async {
    expect(pg.url, startsWith('postgresql://'));

    // Not `test_db`: every suite gets its own database inside the shared
    // container, so suites running at the same time never see each other's
    // tables. Teardown drops it.
    expect(pg.database, isNot('test_db'));

    // Only the port is checked here, because this package depends on no
    // Postgres client by design: implementing md5, SCRAM and TLS on the
    // client side is exactly what tests using it are usually there to
    // verify. Hand `pg.url` to your own driver.
    final socket = await Socket.connect(pg.host, pg.port);
    addTearDown(socket.close);
    expect(socket.remotePort, pg.port);
  });
}
```

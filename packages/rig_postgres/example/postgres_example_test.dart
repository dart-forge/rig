// A Postgres configured the way your test needs it, with a database of its
// own.
//
// Run it: `dart test example` from this package's directory. It is a test
// rather than a script because that is how the module is used — `usePostgres`
// calls `setUpAll` — and because CI runs it, which keeps it honest.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  // `auth:` is the reason this module exists. Asking for md5 here gives you a
  // server that really stores an md5 verifier — set the method without
  // re-hashing the password and Postgres quietly keeps using SCRAM, so a test
  // that thinks it exercises md5 exercises nothing.
  final pg = usePostgres(auth: PgAuth.md5);

  test('the suite gets a URL and a database of its own', () async {
    // A connection string any Postgres client accepts as-is.
    expect(pg.url, startsWith('postgresql://'));

    // Not `test_db`: every suite gets its own database inside the shared
    // container, so suites running at the same time never see each other's
    // tables. The name carries the project and the run, and teardown drops it.
    expect(pg.database, isNot('test_db'));
    expect(pg.database, startsWith('test_'));

    // Only the port is checked here, because rig deliberately depends on no
    // Postgres client: implementing md5, SCRAM and TLS on the client side is
    // exactly what these tests exist to verify, so a client dependency would
    // be testing this package against itself. In your own tests, hand `pg.url`
    // to `package:postgres` or whatever driver you are testing.
    final socket = await Socket.connect(pg.host, pg.port);
    addTearDown(socket.close);
    expect(socket.remotePort, pg.port);
  });
}

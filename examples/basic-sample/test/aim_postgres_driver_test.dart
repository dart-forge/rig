// The same `usePostgres()` configuration as postgres_driver_test.dart,
// driven by `aim_postgres` instead — a second driver from the rig ecosystem,
// but not rig's own.
//
// The point of this pair of files: because the `usePostgres()` call below is
// identical to the other file's, rig hashes both suites to the same spec and
// hands them the same container, while `PgIsolation.database` (the default)
// still gives each suite a database of its own inside it. Neither file knows
// or cares that the other exists — see the README for how that was checked.
@Tags(['integration'])
library;

import 'package:aim_postgres/aim_postgres.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  // Identical to postgres_driver_test.dart's usePostgres() call on purpose —
  // change either one and the two suites stop sharing a container.
  final pg = usePostgres();

  test('create, insert, and select through a second driver', () async {
    // aim_postgres takes a connection URL rather than an Endpoint. `pg.url`
    // carries no `sslmode` parameter, and this driver defaults an unspecified
    // one to `disable`, so — unlike package:postgres above — nothing extra
    // is needed here to avoid asking for TLS the container never offers.
    final db = await PostgresDatabase.connect(pg.url);
    addTearDown(db.close);

    await db.execute('CREATE TABLE greetings (message TEXT NOT NULL)');
    await db.execute(
      'INSERT INTO greetings (message) VALUES (:message)',
      params: {'message': 'hello from rig'},
    );

    final rows = await db.query('SELECT message FROM greetings');
    expect(rows.single['message'], 'hello from rig');
  });
}

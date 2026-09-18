// `usePostgres()` paired with `package:postgres`, the driver most readers
// reach for. This is the answer to "how do I get a database into my test?":
// create a table, insert a row, read it back through a real client.
@Tags(['integration'])
library;

import 'package:postgres/postgres.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  final pg = usePostgres();

  test('create, insert, and select through a real driver', () async {
    // Built entirely from the lease: change usePostgres's user, password or
    // database and this still connects, because nothing here is a literal
    // that merely happens to match usePostgres()'s defaults.
    final conn = await Connection.open(
      Endpoint(
        host: pg.host,
        port: pg.port,
        database: pg.database,
        username: pg.user,
        password: pg.password,
      ),
      // package:postgres v3 requires TLS unless told otherwise. usePostgres()
      // starts a server with no SSL configured at all (that is what
      // postgresSpec does without a `tls:` argument), so asking this driver
      // for its default leaves it wanting a certificate that will never
      // arrive. Without this line, opening the connection above fails with:
      //   Server does not support SSL, but it was required (default
      //   configuration).
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );
    addTearDown(conn.close);

    await conn.execute('CREATE TABLE greetings (message TEXT NOT NULL)');
    await conn.execute(
      r'INSERT INTO greetings (message) VALUES ($1)',
      parameters: ['hello from rig'],
    );

    final result = await conn.execute('SELECT message FROM greetings');
    expect(result.single[0], 'hello from rig');
  });
}

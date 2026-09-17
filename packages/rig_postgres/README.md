# rig_postgres

A Postgres container for your Dart tests, in the authentication mode you are
actually testing.

```dart
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  final pg = usePostgres(auth: PgAuth.scram);

  test('connects', () async {
    // pg.url is postgresql://test:test@127.0.0.1:<port>/<your own database>
  });
}
```

Suites that ask for the same configuration share one container and each get
their own database inside it, so they do not see each other's tables.

## Testing

```bash
dart test --exclude-tags integration   # no Docker needed
dart test --tags integration           # needs a running Docker daemon
```

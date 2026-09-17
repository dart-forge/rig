# Example

The runnable example lives at [examples/basic-sample](../../../examples/basic-sample)
in this repository, as two test files. rig is a library your *tests* use, so an
example that is not a test would misrepresent it — and keeping it there means
continuous integration runs it on every push, which is what stops it from
quietly rotting as the API moves.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  // At the top of main(), not inside setUpAll: rig installs its own setUpAll,
  // so the container is ready before your first test runs.
  final cache = useContainer(
    const ContainerSpec(
      image: 'redis:7-alpine',
      exposedPorts: [6379],
      waitFor: WaitFor.port(6379),
    ),
  );

  test('talks to redis', () async {
    // Never 6379 on the host — Docker picked the port, which is what keeps
    // this from colliding with a Redis you already run locally.
    final socket = await Socket.connect(cache.host, cache.port(6379));
    addTearDown(socket.close);

    socket.write('*1\r\n\$4\r\nPING\r\n');
    expect(
      await socket.map(utf8.decode).first,
      '+PONG\r\n',
    );
  });
}
```

`examples/basic-sample` also shows `rig_postgres`, where the container's
configuration — the authentication method, a database per suite — is the part
that matters.

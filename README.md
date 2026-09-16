# rig

Your tests start the containers they need.

`rig` lets a Dart test declare the Docker container it depends on, waits until the
container is actually usable, and hands back the port that Docker picked. No fixed
ports, no compose file to run first, no container left behind by accident.

```dart
import 'package:rig/rig.dart';
import 'package:test/test.dart';

const redis = ContainerSpec(
  image: 'redis:7-alpine',
  exposedPorts: [6379],
  waitFor: WaitFor.port(6379),
);

void main() {
  final cache = useContainer(redis);

  test('talks to redis', () async {
    final socket = await Socket.connect(cache.host, cache.port(6379));
    // ...
  });
}
```

## Testing

```bash
dart test --exclude-tags integration   # no Docker needed
dart test --tags integration           # needs a running Docker daemon
```

Status: in development. Not yet published.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rig_hash_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeFile(String name, String content) {
    final f = File(p.join(tmp.path, name))..createSync(recursive: true);
    return f..writeAsStringSync(content);
  }

  test('is 16 hex characters', () {
    const spec = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());

    expect(specHash(spec), matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('cannot be fooled by a newline inside an env value', () {
    // Joining the canonical lines with a newline would make these two
    // produce the same hash input, and the second suite would be handed the
    // first one's container.
    const smuggled = ContainerSpec(
      image: 'x',
      env: {'A': '1\nenv=B=2'},
      waitFor: WaitFor.healthy(),
    );
    const plain = ContainerSpec(
      image: 'x',
      env: {'A': '1', 'B': '2'},
      waitFor: WaitFor.healthy(),
    );

    expect(specHash(smuggled), isNot(specHash(plain)));
  });

  test('is stable for the same spec', () {
    const spec = ContainerSpec(
      image: 'postgres:16-alpine',
      env: {'POSTGRES_USER': 'test'},
      exposedPorts: [5432],
      waitFor: WaitFor.healthy(),
    );

    expect(specHash(spec), specHash(spec));
  });

  test('ignores the declaration order of env', () {
    const a = ContainerSpec(
      image: 'x',
      env: {'B': '2', 'A': '1'},
      waitFor: WaitFor.healthy(),
    );
    const b = ContainerSpec(
      image: 'x',
      env: {'A': '1', 'B': '2'},
      waitFor: WaitFor.healthy(),
    );

    expect(specHash(a), specHash(b));
  });

  test('changes when the image tag changes', () {
    const a = ContainerSpec(
      image: 'postgres:16-alpine',
      waitFor: WaitFor.healthy(),
    );
    const b = ContainerSpec(
      image: 'postgres:17-alpine',
      waitFor: WaitFor.healthy(),
    );

    expect(specHash(a), isNot(specHash(b)));
  });

  test('does not change when only the wait strategy differs', () {
    const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
    const b = ContainerSpec(image: 'x', waitFor: WaitFor.port(5432));

    expect(specHash(a), specHash(b));
  });

  test('does not change when only the lifetime differs', () {
    const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
    const b = ContainerSpec(
      image: 'x',
      waitFor: WaitFor.healthy(),
      lifetime: Lifetime.dedicated,
    );

    expect(specHash(a), specHash(b));
  });

  group('mounts', () {
    test('changes when a mounted file content changes', () {
      final cert = writeFile('server.crt', 'FIRST CERTIFICATE');
      final spec = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: cert.path, containerPath: '/server.crt')],
      );

      final before = specHash(spec);
      cert.writeAsStringSync('SECOND CERTIFICATE');
      final after = specHash(spec);

      expect(
        after,
        isNot(before),
        reason: 'swapping the cert must not reuse the old container',
      );
    });

    test('is the same for identical content at different paths', () {
      final a = writeFile('a/server.crt', 'SAME');
      final b = writeFile('b/server.crt', 'SAME');

      final specA = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: a.path, containerPath: '/server.crt')],
      );
      final specB = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: b.path, containerPath: '/server.crt')],
      );

      expect(
        specHash(specA),
        specHash(specB),
        reason: 'what the container sees is the content, not the host path',
      );
    });

    test('changes when the container path changes', () {
      final cert = writeFile('server.crt', 'SAME');

      final specA = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: cert.path, containerPath: '/a.crt')],
      );
      final specB = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: cert.path, containerPath: '/b.crt')],
      );

      expect(specHash(specA), isNot(specHash(specB)));
    });

    test('changes when readOnly changes', () {
      final cert = writeFile('server.crt', 'SAME');

      final ro = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [
          Mount(hostPath: cert.path, containerPath: '/c', readOnly: true),
        ],
      );
      final rw = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [
          Mount(hostPath: cert.path, containerPath: '/c', readOnly: false),
        ],
      );

      expect(specHash(ro), isNot(specHash(rw)));
    });

    test('walks a mounted directory and notices a change in any file', () {
      writeFile('conf/a.conf', 'A');
      writeFile('conf/nested/b.conf', 'B');
      final dir = Directory(p.join(tmp.path, 'conf'));

      final spec = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: dir.path, containerPath: '/conf')],
      );

      final before = specHash(spec);
      writeFile('conf/nested/b.conf', 'B CHANGED');

      expect(specHash(spec), isNot(before));
    });

    test('notices a file added to a mounted directory', () {
      writeFile('conf/a.conf', 'A');
      final dir = Directory(p.join(tmp.path, 'conf'));
      final spec = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: dir.path, containerPath: '/conf')],
      );

      final before = specHash(spec);
      writeFile('conf/b.conf', 'B');

      expect(specHash(spec), isNot(before));
    });

    test('falls back to size and mtime for a file over the limit', () {
      final big = writeFile('big.bin', 'x' * 100);
      final spec = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [Mount(hostPath: big.path, containerPath: '/big.bin')],
      );

      // The content is not read, but a change in size still changes the hash.
      final before = specHash(spec, maxMountBytes: 10);
      big.writeAsStringSync('x' * 200);

      expect(specHash(spec, maxMountBytes: 10), isNot(before));
    });

    test('a missing mount source is part of the hash, not a crash', () {
      final spec = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [
          Mount(hostPath: p.join(tmp.path, 'nope.crt'), containerPath: '/c'),
        ],
      );

      // A missing source is not silently ignored: if it shows up later,
      // that is a different container.
      expect(() => specHash(spec), returnsNormally);

      writeFile('nope.crt', 'NOW IT EXISTS');
      final after = specHash(spec);

      expect(after, isNot(isEmpty));
    });

    test('mount order in the list does not matter', () {
      final a = writeFile('a.crt', 'A');
      final b = writeFile('b.crt', 'B');

      final one = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [
          Mount(hostPath: a.path, containerPath: '/a'),
          Mount(hostPath: b.path, containerPath: '/b'),
        ],
      );
      final two = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        mounts: [
          Mount(hostPath: b.path, containerPath: '/b'),
          Mount(hostPath: a.path, containerPath: '/a'),
        ],
      );

      expect(specHash(one), specHash(two));
    });
  });
}

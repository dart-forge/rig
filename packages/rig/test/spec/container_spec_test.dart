import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  group('ContainerSpec', () {
    test('can be built as a const', () {
      // Const-constructibility is what sharing rests on; compiling is the assertion.
      const spec = ContainerSpec(
        image: 'redis:7-alpine',
        exposedPorts: [6379],
        waitFor: WaitFor.port(6379),
      );
      expect(spec.image, 'redis:7-alpine');
      expect(spec.lifetime, Lifetime.shared, reason: 'sharing is the default');
    });
  });

  group('normalizeSpec', () {
    test('sorts env by key so declaration order stops mattering', () {
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

      expect(normalizeSpec(a).canonicalLines, normalizeSpec(b).canonicalLines);
    });

    test('sorts exposed ports and drops duplicates', () {
      const spec = ContainerSpec(
        image: 'x',
        exposedPorts: [8080, 80, 8080],
        waitFor: WaitFor.healthy(),
      );

      expect(normalizeSpec(spec).canonicalLines, contains('port=80'));
      expect(
        normalizeSpec(spec).canonicalLines
            .where((l) => l == 'port=8080')
            .length,
        1,
      );
    });

    test('keeps command order, because argv order is meaningful', () {
      const a = ContainerSpec(
        image: 'x',
        command: ['postgres', '-c', 'log_statement=all'],
        waitFor: WaitFor.healthy(),
      );
      const b = ContainerSpec(
        image: 'x',
        command: ['-c', 'log_statement=all', 'postgres'],
        waitFor: WaitFor.healthy(),
      );

      expect(
        normalizeSpec(a).canonicalLines,
        isNot(normalizeSpec(b).canonicalLines),
      );
    });

    test('sorts tmpfs paths', () {
      const spec = ContainerSpec(
        image: 'x',
        tmpfs: {'/b', '/a'},
        waitFor: WaitFor.healthy(),
      );

      final tmpfsLines = normalizeSpec(spec).canonicalLines
          .where((l) => l.startsWith('tmpfs='));
      expect(tmpfsLines, ['tmpfs=/a', 'tmpfs=/b']);
    });

    test('excludes the host path of a mount: the container sees content, '
        'not where it came from', () {
      // Two checkouts at different absolute paths must still share a
      // container. The content itself is folded in by specHash.
      const here = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        mounts: [Mount(hostPath: '/a/server.crt', containerPath: '/c')],
      );
      const there = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        mounts: [Mount(hostPath: '/b/server.crt', containerPath: '/c')],
      );

      expect(
        normalizeSpec(here).canonicalLines,
        normalizeSpec(there).canonicalLines,
      );
    });

    test('includes the container path and access mode of a mount', () {
      const ro = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        mounts: [Mount(hostPath: '/h', containerPath: '/c')],
      );
      const elsewhere = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        mounts: [Mount(hostPath: '/h', containerPath: '/other')],
      );
      const rw = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        mounts: [Mount(hostPath: '/h', containerPath: '/c', readOnly: false)],
      );

      expect(
        normalizeSpec(ro).canonicalLines,
        isNot(normalizeSpec(elsewhere).canonicalLines),
      );
      expect(
        normalizeSpec(ro).canonicalLines,
        isNot(normalizeSpec(rw).canonicalLines),
      );
    });

    test(
      'excludes waitFor: the wait strategy does not change the container',
      () {
        const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
        const b = ContainerSpec(image: 'x', waitFor: WaitFor.port(5432));

        expect(
          normalizeSpec(a).canonicalLines,
          normalizeSpec(b).canonicalLines,
        );
      },
    );

    test('excludes lifetime: shared and dedicated are the same container', () {
      const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
      const b = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        lifetime: Lifetime.dedicated,
      );

      expect(normalizeSpec(a).canonicalLines, normalizeSpec(b).canonicalLines);
    });

    test('excludes the caller own labels', () {
      const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
      const b = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        labels: {'team': 'payments'},
      );

      expect(normalizeSpec(a).canonicalLines, normalizeSpec(b).canonicalLines);
    });

    test('includes the healthcheck, which does change the container', () {
      const a = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
      const b = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        healthcheck: Healthcheck(test: ['CMD', 'true']),
      );

      expect(
        normalizeSpec(a).canonicalLines,
        isNot(normalizeSpec(b).canonicalLines),
      );
    });

    test('includes user, workingDir, privileged and networkMode', () {
      const base = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());
      const withUser = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        user: '1000:1000',
      );
      const withWorkingDir = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        workingDir: '/app',
      );
      const withPrivileged = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        privileged: true,
      );
      const withNetworkMode = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        networkMode: 'host',
      );

      // All four are named in this test's title, so all four are varied.
      for (final other in [
        withUser,
        withWorkingDir,
        withPrivileged,
        withNetworkMode,
      ]) {
        expect(
          normalizeSpec(base).canonicalLines,
          isNot(normalizeSpec(other).canonicalLines),
        );
      }
    });

    test('canonical lines are stable across calls', () {
      const spec = ContainerSpec(
        image: 'postgres:16-alpine',
        env: {'POSTGRES_USER': 'test'},
        exposedPorts: [5432],
        waitFor: WaitFor.healthy(),
      );

      expect(
        normalizeSpec(spec).canonicalLines,
        normalizeSpec(spec).canonicalLines,
      );
    });
  });

  group('WaitFor', () {
    test('healthy describes itself', () {
      expect(
        const WaitFor.healthy().description,
        'health status to become healthy',
      );
    });

    test('port describes itself with the container port', () {
      expect(
        const WaitFor.port(5432).description,
        'port 5432 to accept connections',
      );
    });

    test('httpOk describes itself with path and status', () {
      expect(
        const WaitFor.httpOk(8080, path: '/healthz').description,
        'GET /healthz on port 8080 to answer 200',
      );
    });

    test('all takes the longest timeout of its parts', () {
      const strategy = WaitFor.all([
        WaitFor.port(5432, timeout: Duration(seconds: 10)),
        WaitFor.healthy(timeout: Duration(seconds: 90)),
      ]);

      expect(strategy.timeout, const Duration(seconds: 90));
    });

    test('all joins the descriptions of its parts', () {
      const strategy = WaitFor.all([WaitFor.port(5432), WaitFor.healthy()]);

      expect(strategy.description, contains('port 5432'));
      expect(strategy.description, contains('healthy'));
    });

    test('default timeout is 60 seconds', () {
      expect(const WaitFor.healthy().timeout, const Duration(seconds: 60));
      expect(const WaitFor.port(1).timeout, const Duration(seconds: 60));
    });
  });
}

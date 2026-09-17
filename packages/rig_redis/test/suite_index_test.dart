import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_redis/src/suite_index.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  late String containerId;
  late Directory tmp;
  late StateDir stateDir;
  final now = DateTime.utc(2026, 9, 17, 10, 30);

  setUp(() {
    engine = FakeDockerEngine()
      ..onExec = (_) => const ExecResult(exitCode: 0, output: 'OK');
    containerId = engine.addContainer(labels: const {});
    tmp = Directory.systemTemp.createTempSync('rig_redis_idx_');
    stateDir = StateDir(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('suiteIndexMarker', () {
    test(
      'lives under <stateDir>/redis/<containerId>/<index>, not suitesDir',
      () {
        final marker = suiteIndexMarker(
          stateDir: stateDir,
          containerId: 'abc',
          index: 3,
        );

        expect(marker.path, p.join(tmp.path, 'redis', 'abc', '3'));
        expect(
          p.isWithin(stateDir.suitesDir.path, marker.path),
          isFalse,
          reason:
              'a Redis index is recycled by this module on its own schedule, '
              'not the one rig prune sweeps suitesDir on',
        );
      },
    );
  });

  group('claimSuiteIndex', () {
    test('two claims on the same container in the same run get different '
        'indices, and neither is 0', () async {
      final first = await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );
      final second = await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );

      expect(first, isNot(second));
      expect(first, isNot(0));
      expect(second, isNot(0));
      // Smallest free index first, and allocation starts at 1: index 0 is
      // reserved for RedisIsolation.none.
      expect(first, 1);
      expect(second, 2);
    });

    test('marks the claimed index so a later claim skips it', () async {
      final chosen = await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );

      final marker = suiteIndexMarker(
        stateDir: stateDir,
        containerId: containerId,
        index: chosen,
      );
      expect(marker.existsSync(), isTrue);
    });

    test('flushes the index it hands out', () async {
      await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );

      expect(
        engine.calls.any((c) => c.contains('FLUSHDB') && c.contains('-n 1')),
        isTrue,
      );
    });

    test(
      'authenticates its FLUSHDB when the container has a password',
      () async {
        await claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 16,
          password: 'hunter2',
          now: now,
          stateDir: stateDir,
        );

        expect(
          engine.calls.last,
          contains("-a hunter2 --no-auth-warning -n 1 FLUSHDB"),
        );
      },
    );

    test(
      'a marker older than markerStaleAfter is reclaimed, and FLUSHDB '
      "clears whatever the crashed suite left behind — mutation: remove "
      'the FLUSHDB call and this fails with the old key still visible',
      () async {
        // A tiny simulated Redis: one map of keys per database index, driven
        // by the same redis-cli argument shape the real module sends.
        final store = <int, Map<String, String>>{};
        engine.onExec = (command) {
          final args = command.skip(1).toList();
          var index = 0;
          if (args.isNotEmpty && args.first == '-n') {
            index = int.parse(args[1]);
            args.removeRange(0, 2);
          }
          final db = store.putIfAbsent(index, () => {});
          switch (args.first.toUpperCase()) {
            case 'SET':
              db[args[1]] = args[2];
              return const ExecResult(exitCode: 0, output: 'OK');
            case 'GET':
              return ExecResult(exitCode: 0, output: db[args[1]] ?? '');
            case 'FLUSHDB':
              db.clear();
              return const ExecResult(exitCode: 0, output: 'OK');
            default:
              return const ExecResult(exitCode: 1, output: 'unsupported');
          }
        };

        // A previous suite claimed index 1, wrote a key, and never reached
        // teardown — its marker is still there, aged past markerStaleAfter.
        final marker = suiteIndexMarker(
          stateDir: stateDir,
          containerId: containerId,
          index: 1,
        );
        marker.parent.createSync(recursive: true);
        marker.writeAsStringSync('');
        marker.setLastModifiedSync(now.subtract(const Duration(hours: 25)));
        store[1] = {'ghost': 'left by a crashed suite'};

        final claimed = await claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 16,
          password: null,
          now: now,
          stateDir: stateDir,
        );

        expect(
          claimed,
          1,
          reason:
              'index 1 is the only one free, once its stale marker no '
              'longer protects it',
        );

        // The load-bearing assertion: the crashed suite's own key must not
        // be visible to whoever claims this index next. Checked before the
        // "a FLUSHDB call happened" assertion below on purpose, so a
        // mutation that skips the flush shows up here first, with the
        // leftover key it actually left behind.
        final leftover = await engine.exec(containerId, [
          'redis-cli',
          '-n',
          '1',
          'GET',
          'ghost',
        ]);
        expect(
          leftover.output,
          isEmpty,
          reason:
              "the crashed suite's key must not be visible to whoever "
              'claims this index next',
        );

        expect(
          engine.calls.any((c) => c.contains('FLUSHDB') && c.contains('-n 1')),
          isTrue,
        );
      },
    );

    test('a marker aged just under markerStaleAfter still protects its index '
        '— old enough that a shorter, wrong threshold would wrongly reclaim '
        'it — mutation: delete the age comparison and this fails', () async {
      // Only one index exists to claim at all (databases: 2 -> capacity 1,
      // index 0 reserved), and its marker is aged just under the real
      // 24-hour threshold. Any shorter threshold — a typo, or a stray
      // reuse of some other constant — would call this stale; only
      // comparing against the correct 24 hours keeps it claimed, so this
      // ages the marker where the right and a wrong answer disagree
      // rather than somewhere both would happen to agree.
      final marker = suiteIndexMarker(
        stateDir: stateDir,
        containerId: containerId,
        index: 1,
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(now.subtract(const Duration(hours: 23)));

      await expectLater(
        claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 2,
          password: null,
          now: now,
          stateDir: stateDir,
        ),
        throwsA(isA<RedisDatabasesExhausted>()),
        reason:
            'the only index is still protected by its marker, so '
            'there is nothing free to hand out',
      );
    });

    test('throws when every index is claimed, naming how many are in use and '
        'both ways out', () async {
      // databases: 2 -> capacity 1 (index 0 is reserved). The first claim
      // takes the only index there is.
      await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 2,
        password: null,
        now: now,
        stateDir: stateDir,
      );

      await expectLater(
        claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 2,
          password: null,
          now: now,
          stateDir: stateDir,
        ),
        throwsA(
          isA<RedisDatabasesExhausted>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('1 of 1'),
              contains('databases:'),
              contains('Lifetime.dedicated'),
              contains('shared with other projects'),
            ),
          ),
        ),
      );
    });

    test('fails loudly rather than handing out an index it could not confirm '
        'was flushed', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERR unknown command');

      await expectLater(
        claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 16,
          password: null,
          now: now,
          stateDir: stateDir,
        ),
        throwsA(
          isA<RedisIndexNotFlushed>().having(
            (e) => e.message,
            'message',
            contains('unknown command'),
          ),
        ),
      );
    });

    test('treats an exit-0 reply that is not OK as a failed flush, the same '
        'way the injected healthcheck distrusts a 0 exit code', () async {
      // redis-cli can exit 0 while printing an error, e.g. NOAUTH — the
      // same reason redisSpec's own healthcheck greps for PONG instead of
      // trusting the exit code.
      engine.onExec = (_) => const ExecResult(
        exitCode: 0,
        output: 'NOAUTH Authentication required.',
      );

      await expectLater(
        claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 16,
          password: null,
          now: now,
          stateDir: stateDir,
        ),
        throwsA(isA<RedisIndexNotFlushed>()),
      );
    });

    test('does not leave a marker behind when the flush fails, so a retry can '
        'still claim the same index', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERR unknown command');

      await expectLater(
        claimSuiteIndex(
          engine: engine,
          containerId: containerId,
          databases: 16,
          password: null,
          now: now,
          stateDir: stateDir,
        ),
        throwsA(isA<RedisIndexNotFlushed>()),
      );

      final marker = suiteIndexMarker(
        stateDir: stateDir,
        containerId: containerId,
        index: 1,
      );
      expect(marker.existsSync(), isFalse);
    });
  });

  group('releaseSuiteIndex', () {
    test('flushes the index and clears its marker', () async {
      final claimed = await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );
      final marker = suiteIndexMarker(
        stateDir: stateDir,
        containerId: containerId,
        index: claimed,
      );
      expect(marker.existsSync(), isTrue);

      await releaseSuiteIndex(
        engine: engine,
        containerId: containerId,
        index: claimed,
        password: null,
        stateDir: stateDir,
      );

      expect(marker.existsSync(), isFalse);
      expect(
        engine.calls.last,
        contains('FLUSHDB'),
        reason:
            'freeing the index promptly is the normal fast path; the '
            'markerStaleAfter sweep in claimSuiteIndex is only the fallback '
            'for a suite that never reaches teardown',
      );
    });

    test('does not throw, and leaves the marker for a later claim to reclaim, '
        'when Docker itself could not run the flush', () async {
      final claimed = await claimSuiteIndex(
        engine: engine,
        containerId: containerId,
        databases: 16,
        password: null,
        now: now,
        stateDir: stateDir,
      );
      final marker = suiteIndexMarker(
        stateDir: stateDir,
        containerId: containerId,
        index: claimed,
      );

      engine.onExec = (_) => throw EngineError(
        method: 'POST',
        path: '/containers/$containerId/exec',
        statusCode: 404,
        body: 'No such container',
      );

      await expectLater(
        releaseSuiteIndex(
          engine: engine,
          containerId: containerId,
          index: claimed,
          password: null,
          stateDir: stateDir,
        ),
        completes,
      );
      expect(
        marker.existsSync(),
        isTrue,
        reason:
            'the container is gone, so nothing here can tell whether '
            'the index went with it',
      );
    });
  });
}

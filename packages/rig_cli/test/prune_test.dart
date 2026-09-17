import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_cli/src/prune.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  late Directory tmp;
  late StateDir state;
  late List<String> lines;

  final now = DateTime.utc(2026, 9, 16, 12);

  setUp(() {
    engine = FakeDockerEngine();
    tmp = Directory.systemTemp.createTempSync('rig_prune_');
    state = StateDir(tmp)..ensure();
    lines = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int> prune({
    Duration olderThan = const Duration(days: 7),
    bool all = false,
    bool failedOnly = false,
  }) => runPrune(
    engine: engine,
    stateDir: state,
    out: lines.add,
    now: now,
    olderThan: olderThan,
    all: all,
    failedOnly: failedOnly,
  );

  String id(
    String hash, {
    required DateTime created,
    String lifetime = 'shared',
    String? network,
  }) => engine.addContainer(
    labels: {
      rigMarkerLabel: '1',
      rigHashLabel: hash,
      rigLifetimeLabel: lifetime,
      rigSummaryLabel: 'postgres:16-alpine',
    },
    created: created,
    network: network,
  );

  test('removes containers older than the threshold', () async {
    final old = id('old', created: DateTime.utc(2026, 9, 1));
    final fresh = id('fresh', created: DateTime.utc(2026, 9, 16, 6));

    expect(await prune(), 0);

    expect(engine.calls, contains('remove:$old'));
    expect(engine.calls.contains('remove:$fresh'), isFalse);
  });

  test('says how many it removed', () async {
    id('old', created: DateTime.utc(2026, 9, 1));

    await prune();

    expect(lines.join('\n'), contains('1'));
  });

  test('says so when there is nothing to remove', () async {
    id('fresh', created: DateTime.utc(2026, 9, 16, 6));

    await prune();

    expect(lines.join('\n'), contains('Nothing'));
  });

  test('all removes everything rig made, whatever its age', () async {
    final fresh = id('fresh', created: DateTime.utc(2026, 9, 16, 11, 59));

    await prune(all: true);

    expect(engine.calls, contains('remove:$fresh'));
  });

  test('never touches a container rig did not make', () async {
    final foreign = engine.addContainer(
      labels: {'com.example.thing': '1'},
      created: DateTime.utc(2020, 1, 1),
    );

    await prune(all: true);

    expect(engine.calls.contains('remove:$foreign'), isFalse);
  });

  test('leaves dedicated containers alone unless all is given', () async {
    // A dedicated container belongs to whoever made it: however old it looks,
    // it may be serving a suite that is running right now.
    final dedicated = id(
      'd',
      created: DateTime.utc(2026, 9, 1),
      lifetime: 'dedicated',
    );

    await prune();

    expect(engine.calls.contains('remove:$dedicated'), isFalse);

    await prune(all: true);

    expect(engine.calls, contains('remove:$dedicated'));
  });

  group('failed', () {
    test('removes only the containers with a failure marker', () async {
      final failed = id('f', created: DateTime.utc(2026, 9, 16, 11));
      final healthy = id('h', created: DateTime.utc(2026, 9, 16, 11));
      state
          .failedMarker(failed)
          .writeAsStringSync(
            jsonEncode({'containerId': failed, 'image': 'postgres:16-alpine'}),
          );

      await prune(failedOnly: true);

      expect(engine.calls, contains('remove:$failed'));
      expect(engine.calls.contains('remove:$healthy'), isFalse);
    });

    test('deletes the marker afterwards', () async {
      final failed = id('f', created: DateTime.utc(2026, 9, 16, 11));
      state.failedMarker(failed).writeAsStringSync('{}');

      await prune(failedOnly: true);

      expect(state.failedMarker(failed).existsSync(), isFalse);
    });

    test('clears a marker whose container is already gone', () async {
      state.failedMarker('vanished').writeAsStringSync('{}');

      await prune(failedOnly: true);

      expect(state.failedMarker('vanished').existsSync(), isFalse);
    });
  });

  test('never touches a container whose labels are incomplete', () async {
    // This one reaches the label filter — the marker key is there — but has
    // no usable identity, so only the parse guard can exclude it. Without a
    // test of its own, the filter would hide a regression here.
    final partial = engine.addContainer(
      labels: {rigMarkerLabel: '1'},
      created: DateTime.utc(2020, 1, 1),
    );

    await prune(all: true);

    expect(engine.calls.contains('remove:$partial'), isFalse);
  });

  test('clears a marker for a vanished container without any flag', () async {
    state.failedMarker('vanished').writeAsStringSync('{}');

    await prune();

    expect(
      state.failedMarker('vanished').existsSync(),
      isFalse,
      reason: 'markers must not pile up through ordinary use',
    );
  });

  test('clears failure markers for containers it removed', () async {
    final old = id('old', created: DateTime.utc(2026, 9, 1));
    state.failedMarker(old).writeAsStringSync('{}');

    await prune();

    expect(state.failedMarker(old).existsSync(), isFalse);
  });

  group('suite marker directories', () {
    // A suite marker directory is <suitesDir>/<containerId>/<database>,
    // written by rig_postgres's createSuiteDatabase. Removing a container
    // takes its tmpfs PGDATA with it, so a marker whose container is gone
    // protects nothing that still exists — and only prune ever looks at a
    // container that is no longer live, so only prune can reclaim it.
    Directory suiteDir(String containerId) =>
        Directory(p.join(state.suitesDir.path, containerId));

    test(
      'reclaims a suite directory whose container no longer exists',
      () async {
        suiteDir('vanished').createSync(recursive: true);
        File(p.join(suiteDir('vanished').path, 'test_p_1_deadbeef'))
            .writeAsStringSync('');

        await prune();

        expect(suiteDir('vanished').existsSync(), isFalse);
      },
    );

    test(
      'leaves a suite directory alone while its container is live',
      () async {
        final alive = id('alive', created: DateTime.utc(2026, 9, 16, 11, 59));
        suiteDir(alive).createSync(recursive: true);

        await prune();

        expect(suiteDir(alive).existsSync(), isTrue);
      },
    );

    test(
      'reclaims a suite directory for a container this same run removes',
      () async {
        final removed = id('r', created: DateTime.utc(2026, 9, 1));
        suiteDir(removed).createSync(recursive: true);

        await prune();

        expect(engine.calls, contains('remove:$removed'));
        expect(suiteDir(removed).existsSync(), isFalse);
      },
    );

    test('reports how many stale suite directories it reclaimed', () async {
      suiteDir('vanished').createSync(recursive: true);

      await prune();

      expect(lines.join('\n'), contains('1 stale suite director'));
    });

    test('does nothing when there are no suite directories at all', () async {
      // suitesDir may not exist yet on a machine that has never run a
      // module built on createSuiteDatabase.
      await expectLater(prune(), completes);
    });
  });

  group('networks', () {
    test('removes a rig network with no containers attached', () async {
      final netId = engine.addNetwork(
        name: 'rig-app',
        labels: {rigMarkerLabel: '1'},
      );

      await prune(all: true);

      expect(engine.calls, contains('removeNetwork:$netId'));
      expect(await engine.listNetworks(), isEmpty);
    });

    test('reports the network it removed', () async {
      engine.addNetwork(name: 'rig-app', labels: {rigMarkerLabel: '1'});

      await prune(all: true);

      expect(lines.join('\n'), contains('removed network rig-app'));
    });

    test('counts networks in the summary line', () async {
      engine.addNetwork(name: 'rig-app', labels: {rigMarkerLabel: '1'});

      await prune(all: true);

      expect(lines.join('\n'), contains('1 network(s)'));
    });

    test('never touches a network without rig\'s label', () async {
      final foreign = engine.addNetwork(name: 'someone-elses-net');

      await prune(all: true);

      expect(engine.calls.contains('removeNetwork:$foreign'), isFalse);
    });

    test(
      'leaves a network with an active endpoint alone, and says so',
      () async {
        engine.addNetwork(
          name: 'rig-busy',
          labels: {rigMarkerLabel: '1'},
          connectedContainerIds: ['still-there'],
        );

        await prune(all: true);

        expect(
          lines.join('\n'),
          contains('network(s) still in use, not removed: rig-busy'),
        );
        final networks = await engine.listNetworks();
        expect(
          networks,
          hasLength(1),
          reason: 'a network prune could not remove must still be there',
        );
      },
    );

    test(
      'removes a container and its now-empty network in the same run',
      () async {
        // Order matters: if the network were attempted before the container
        // that made it unremovable, this would incorrectly report it as
        // still in use.
        final containerId = id(
          'old',
          created: DateTime.utc(2026, 9, 1),
          network: 'rig-app',
        );
        engine.addNetwork(
          name: 'rig-app',
          labels: {rigMarkerLabel: '1'},
          connectedContainerIds: [containerId],
        );

        await prune();

        expect(engine.calls, contains('remove:$containerId'));
        expect(await engine.listNetworks(), isEmpty);
        expect(
          lines.join('\n'),
          isNot(contains('still in use')),
          reason:
              'the container that made it busy was removed in this same run',
        );
      },
    );

    test('says nothing about networks when there are none', () async {
      await prune();

      expect(lines.join('\n'), contains('Nothing to remove.'));
    });
  });
}

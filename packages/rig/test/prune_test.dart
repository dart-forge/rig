import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  late Directory tmp;
  late StateDir state;

  final now = DateTime.utc(2026, 9, 16, 12);

  setUp(() {
    engine = FakeDockerEngine();
    tmp = Directory.systemTemp.createTempSync('rig_prune_');
    state = StateDir(tmp)..ensure();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<PruneResult> prune({
    Duration olderThan = const Duration(days: 7),
    Duration dedicatedOlderThan = const Duration(hours: 1),
    bool all = false,
    bool failedOnly = false,
  }) => pruneContainers(
    engine: engine,
    stateDir: state,
    now: now,
    olderThan: olderThan,
    dedicatedOlderThan: dedicatedOlderThan,
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

  test('defaults resolve without an explicit engine', () async {
    // pruneContainers() with no engine reaches for currentEngine() rather
    // than requiring a caller to connect one itself — the same seam
    // useContainer() uses. A temporary StateDir keeps this hermetic: the
    // point here is only the engine default, and pairing that with the
    // real ~/.rig would let this test clear a developer's own failure
    // markers and marker directories for real.
    final fake = FakeDockerEngine();
    overrideEngine(fake);
    addTearDown(resetEngine);

    await pruneContainers(stateDir: state, now: now);

    expect(fake.calls, contains('list'));
    expect(fake.calls, contains('listNetworks'));
  });

  test('removes containers older than the threshold', () async {
    final old = id('old', created: DateTime.utc(2026, 9, 1));
    final fresh = id('fresh', created: DateTime.utc(2026, 9, 16, 6));

    await prune();

    expect(engine.calls, contains('remove:$old'));
    expect(engine.calls.contains('remove:$fresh'), isFalse);
  });

  test('the result says how many it removed', () async {
    final old = id('old', created: DateTime.utc(2026, 9, 1));

    final result = await prune();

    expect(result.removedContainers, hasLength(1));
    expect(result.removedContainers.single.id, old);
  });

  test('the result reports nothing when there is nothing to remove', () async {
    id('fresh', created: DateTime.utc(2026, 9, 16, 6));

    final result = await prune();

    expect(result.removedContainers, isEmpty);
    expect(result.removedNetworks, isEmpty);
    expect(result.clearedFailureMarkers, 0);
    expect(result.clearedMarkerDirectories, 0);
  });

  test('all removes everything rig made, whatever its age', () async {
    final fresh = id('fresh', created: DateTime.utc(2026, 9, 16, 11, 59));

    final result = await prune(all: true);

    expect(engine.calls, contains('remove:$fresh'));
    expect(result.removedContainers.map((c) => c.id), contains(fresh));
  });

  test('never touches a container rig did not make', () async {
    final foreign = engine.addContainer(
      labels: {'com.example.thing': '1'},
      created: DateTime.utc(2020, 1, 1),
    );

    await prune(all: true);

    expect(engine.calls.contains('remove:$foreign'), isFalse);
  });

  group('dedicated containers', () {
    // A dedicated container is created for one suite and removed at that
    // suite's teardown, so its age is essentially that suite's runtime. One
    // still around past the (much shorter) dedicated cutoff has outlived any
    // plausible suite and can only be a leak from a suite killed before
    // teardown ran.
    test('removes a dedicated container two hours old', () async {
      final leaked = id(
        'd',
        created: now.subtract(const Duration(hours: 2)),
        lifetime: 'dedicated',
      );

      await prune();

      expect(engine.calls, contains('remove:$leaked'));
    });

    test('leaves a dedicated container thirty minutes old alone', () async {
      final inUse = id(
        'd',
        created: now.subtract(const Duration(minutes: 30)),
        lifetime: 'dedicated',
      );

      await prune();

      expect(engine.calls.contains('remove:$inUse'), isFalse);
    });

    test('does not change the shared cutoff', () async {
      // A shared container's age means something else — how long reuse
      // across runs has been paying off — so the dedicated cutoff must not
      // leak into the shared one: an hour-old shared container stays.
      final sharedYoungerThanSevenDays = id(
        's',
        created: now.subtract(const Duration(hours: 2)),
      );

      await prune();

      expect(
        engine.calls.contains('remove:$sharedYoungerThanSevenDays'),
        isFalse,
      );
    });

    test('all still removes a dedicated container regardless of age', () async {
      final fresh = id(
        'd',
        created: now.subtract(const Duration(minutes: 1)),
        lifetime: 'dedicated',
      );

      await prune(all: true);

      expect(engine.calls, contains('remove:$fresh'));
    });

    test('failed still ignores age for a dedicated container', () async {
      final failed = id(
        'd',
        created: now.subtract(const Duration(minutes: 1)),
        lifetime: 'dedicated',
      );
      state
          .failedMarker(failed)
          .writeAsStringSync(
            jsonEncode({'containerId': failed, 'image': 'postgres:16-alpine'}),
          );

      await prune(failedOnly: true);

      expect(engine.calls, contains('remove:$failed'));
    });

    test('the result separates shared and dedicated removals', () async {
      id('shared-old', created: DateTime.utc(2026, 9, 1));
      id(
        'dedicated-leaked',
        created: now.subtract(const Duration(hours: 2)),
        lifetime: 'dedicated',
      );

      final result = await prune();

      expect(result.sharedRemoved, 1);
      expect(result.dedicatedRemoved, 1);
    });
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
    // A marker directory is <root>/markers/<kind>/<containerId>/<name>,
    // written by a module such as rig_postgres's createSuiteDatabase or
    // rig_redis's claimSuiteIndex. Removing a container takes whatever the
    // marker was protecting with it, so a marker whose container is gone
    // protects nothing that still exists — and only prune ever looks at a
    // container that is no longer live, so only prune can reclaim it.
    Directory kindDir(String containerId, {String kind = 'postgres'}) =>
        Directory(p.join(state.markerDir(kind).path, containerId));

    test(
      'reclaims a marker directory whose container no longer exists',
      () async {
        kindDir('vanished').createSync(recursive: true);
        File(p.join(kindDir('vanished').path, 'test_p_1_deadbeef'))
            .writeAsStringSync('');

        await prune();

        expect(kindDir('vanished').existsSync(), isFalse);
      },
    );

    test(
      'leaves a marker directory alone while its container is live',
      () async {
        final alive = id('alive', created: DateTime.utc(2026, 9, 16, 11, 59));
        kindDir(alive).createSync(recursive: true);

        await prune();

        expect(kindDir(alive).existsSync(), isTrue);
      },
    );

    test(
      'reclaims a marker directory for a container this same run removes',
      () async {
        final removed = id('r', created: DateTime.utc(2026, 9, 1));
        kindDir(removed).createSync(recursive: true);

        await prune();

        expect(engine.calls, contains('remove:$removed'));
        expect(kindDir(removed).existsSync(), isFalse);
      },
    );

    test(
      'the result reports how many stale marker directories it reclaimed',
      () async {
        kindDir('vanished').createSync(recursive: true);

        final result = await prune();

        expect(result.clearedMarkerDirectories, 1);
      },
    );

    test('does nothing when there are no marker directories at all', () async {
      // The markers root may not exist yet on a machine that has never run
      // a module that writes one.
      await expectLater(prune(), completes);
    });

    test('sweeps markers of every kind for a dead container — including one no '
        'module in this repo defines — while leaving a live container\'s '
        'markers of the same kinds alone: the proof that prune decides per '
        '(kind, containerId) pair rather than knowing what any kind is. '
        "Without the live container here, an implementation that dropped "
        "prune's kind level entirely (deleting markers/<kind> wholesale "
        'whenever the kind name itself is not a known container id) would '
        'still pass by coincidence.', () async {
      final alive = id('alive', created: DateTime.utc(2026, 9, 16, 11, 59));

      for (final kind in ['postgres', 'redis', 'somethingelse']) {
        kindDir('vanished', kind: kind).createSync(recursive: true);
        kindDir(alive, kind: kind).createSync(recursive: true);
      }

      await prune();

      for (final kind in ['postgres', 'redis', 'somethingelse']) {
        expect(
          kindDir('vanished', kind: kind).existsSync(),
          isFalse,
          reason:
              'a kind hard-coded prune has never heard of must still be '
              'swept, or this is really just postgres and redis listed by '
              'name',
        );
        expect(
          kindDir(alive, kind: kind).existsSync(),
          isTrue,
          reason:
              'a live container\'s marker must survive regardless of '
              'kind, which only holds if prune looks at containerId '
              'inside each kind rather than at the kind directory itself',
        );
      }
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

    test('the result reports the network it removed', () async {
      engine.addNetwork(name: 'rig-app', labels: {rigMarkerLabel: '1'});

      final result = await prune(all: true);

      expect(result.removedNetworks, ['rig-app']);
    });

    test('never touches a network without rig\'s label', () async {
      final foreign = engine.addNetwork(name: 'someone-elses-net');

      await prune(all: true);

      expect(engine.calls.contains('removeNetwork:$foreign'), isFalse);
    });

    test('leaves a network with an active endpoint alone, and the result says '
        'so', () async {
      engine.addNetwork(
        name: 'rig-busy',
        labels: {rigMarkerLabel: '1'},
        connectedContainerIds: ['still-there'],
      );

      final result = await prune(all: true);

      expect(result.networksStillInUse, ['rig-busy']);
      final networks = await engine.listNetworks();
      expect(
        networks,
        hasLength(1),
        reason: 'a network prune could not remove must still be there',
      );
    });

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

        final result = await prune();

        expect(engine.calls, contains('remove:$containerId'));
        expect(await engine.listNetworks(), isEmpty);
        expect(
          result.networksStillInUse,
          isEmpty,
          reason:
              'the container that made it busy was removed in this same run',
        );
      },
    );
  });
}

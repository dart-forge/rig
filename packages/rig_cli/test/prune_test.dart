import 'dart:convert';
import 'dart:io';

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
  }) => engine.addContainer(
    labels: {
      rigMarkerLabel: '1',
      rigHashLabel: hash,
      rigLifetimeLabel: lifetime,
      rigSummaryLabel: 'postgres:16-alpine',
    },
    created: created,
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
}

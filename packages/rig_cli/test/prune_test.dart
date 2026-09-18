import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_cli/src/prune.dart';
import 'package:test/test.dart';

/// What `runPrune` decides to remove is tested against `pruneContainers`
/// itself, in `rig`'s own test suite — that decision moved there along with
/// the logic. What is left here is the formatting: the words `runPrune`
/// prints for a given [PruneResult], and the flags that shape it.
void main() {
  late FakeDockerEngine engine;
  late Directory tmp;
  late StateDir state;
  late List<String> lines;

  final now = DateTime.utc(2026, 9, 16, 12);

  setUp(() {
    engine = FakeDockerEngine();
    tmp = Directory.systemTemp.createTempSync('rig_cli_prune_');
    state = StateDir(tmp)..ensure();
    lines = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int> prune({
    Duration olderThan = const Duration(days: 7),
    Duration dedicatedOlderThan = const Duration(hours: 1),
    bool all = false,
    bool failedOnly = false,
  }) => runPrune(
    engine: engine,
    stateDir: state,
    out: lines.add,
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

  test('reports shared and dedicated removals separately', () async {
    id('shared-old', created: DateTime.utc(2026, 9, 1));
    id(
      'dedicated-leaked',
      created: now.subtract(const Duration(hours: 2)),
      lifetime: 'dedicated',
    );

    await prune();

    expect(lines.join('\n'), contains('1 shared, 1 dedicated'));
  });

  group('suite marker directories', () {
    test('reports how many stale marker directories it reclaimed', () async {
      // No live container claims this, so pruning reclaims it even though no
      // container in this run is doomed — the count line still has to say
      // so.
      Directory(p.join(state.markerDir('postgres').path, 'vanished'))
          .createSync(recursive: true);

      await prune();

      expect(lines.join('\n'), contains('1 stale marker director'));
    });
  });

  group('networks', () {
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
      },
    );

    test('says nothing about networks when there are none', () async {
      await prune();

      expect(lines.join('\n'), contains('Nothing to remove.'));
    });
  });
}

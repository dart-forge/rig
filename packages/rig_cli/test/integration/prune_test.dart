@Tags(['integration', 'destructive'])
library;

import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_cli/src/prune.dart';
import 'package:test/test.dart';

void main() {
  late DockerEngine engine;

  setUpAll(() async {
    engine = await connectToDocker();
  });

  tearDownAll(() => engine.close());

  test('`rig prune --all` removes a networked container and its network, '
      'without getting stuck on Docker refusing to drop a network that is '
      'still attached', () async {
    final runId = DateTime.now().microsecondsSinceEpoch.toString();
    final networkName = 'it-prune-network-$runId';
    final tmp = Directory.systemTemp.createTempSync('rig_cli_prune_it_');
    final stateDir = StateDir(tmp)..ensure();

    final acquired = await acquireContainer(
      spec: ContainerSpec(
        image: 'alpine:3.20',
        command: const ['sleep', '300'],
        labels: {'dev.dart-forge.rig.test.run': runId},
        healthcheck: const Healthcheck(
          test: ['CMD-SHELL', 'true'],
          interval: Duration(milliseconds: 250),
          retries: 20,
        ),
        waitFor: const WaitFor.healthy(timeout: Duration(seconds: 60)),
        lifetime: Lifetime.dedicated,
        network: ContainerNetwork(networkName),
      ),
      engine: engine,
      stateDir: stateDir,
      project: 'rig_cli_integration',
    );

    // Sanity check on the premise this test relies on: Docker really does
    // refuse to drop a network with this container still attached, which
    // is exactly the trap `runPrune` has to avoid falling into.
    final beforePrune = await engine.listNetworks(
      filters: {
        'label': [rigMarkerLabel],
      },
    );
    final networkId = beforePrune
        .firstWhere((n) => n.name == 'rig-$networkName')
        .id;
    expect(await engine.removeNetwork(networkId), isFalse);

    final lines = <String>[];
    final code = await runPrune(
      engine: engine,
      stateDir: stateDir,
      out: lines.add,
      now: DateTime.now(),
      all: true,
    );

    expect(code, 0);
    expect(
      lines.join('\n'),
      isNot(contains('still in use')),
      reason:
          'the container that was blocking removal was pruned in this '
          'same run, before networks were attempted',
    );

    await expectLater(
      engine.inspectContainer(acquired.containerId),
      throwsA(isA<EngineError>().having((e) => e.statusCode, 'status', 404)),
    );
    final afterPrune = await engine.listNetworks(
      filters: {
        'label': [rigMarkerLabel],
      },
    );
    expect(afterPrune.any((n) => n.id == networkId), isFalse);

    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

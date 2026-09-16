import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_cli/src/duration_arg.dart';
import 'package:rig_cli/src/ls.dart';
import 'package:rig_cli/src/prune.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<int>(
          'rig',
          'Inspect and clean up the containers rig keeps for your tests.',
        )
        ..addCommand(_LsCommand())
        ..addCommand(_PruneCommand());

  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on RigException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}

final class _LsCommand extends Command<int> {
  @override
  String get name => 'ls';

  @override
  String get description => 'List the containers rig is holding.';

  @override
  Future<int> run() async {
    final engine = await connectToDocker();
    try {
      return await runLs(
        engine: engine,
        out: stdout.writeln,
        now: DateTime.now().toUtc(),
      );
    } finally {
      await engine.close();
    }
  }
}

final class _PruneCommand extends Command<int> {
  _PruneCommand() {
    argParser
      ..addOption(
        'older-than',
        help: 'Remove shared containers older than this (7d, 12h, 30m).',
        defaultsTo: '7d',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Remove every container rig made, including dedicated ones.',
      )
      ..addFlag(
        'failed',
        negatable: false,
        help: 'Remove only containers kept after a readiness failure.',
      );
  }

  @override
  String get name => 'prune';

  @override
  String get description => 'Remove containers rig is holding.';

  @override
  Future<int> run() async {
    final olderThan = parseDurationArg(argResults!.option('older-than')!);
    final engine = await connectToDocker();
    try {
      return await runPrune(
        engine: engine,
        stateDir: StateDir.forUser(),
        out: stdout.writeln,
        now: DateTime.now().toUtc(),
        olderThan: olderThan,
        all: argResults!.flag('all'),
        failedOnly: argResults!.flag('failed'),
      );
    } finally {
      await engine.close();
    }
  }
}

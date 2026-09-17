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
        help:
            'Remove shared containers older than this (7d, 12h, 30m). Age '
            'is when Docker created the container, not when it was last '
            'used — Docker exposes no such time — so a bare prune can '
            'remove a long-lived shared container a suite is using right '
            'now. Dedicated containers are not affected by this flag: a '
            'bare prune already removes those past a fixed 1 hour, since '
            'one still around that long has outlived any plausible suite '
            'and can only be a leak from a suite killed before teardown — '
            'though the same risk applies if a suite genuinely runs longer '
            'than that.',
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
        help:
            'Remove only containers kept after a readiness failure. '
            'Wins over --all when both are given.',
      );
  }

  @override
  String get name => 'prune';

  @override
  String get description =>
      'Remove containers rig is holding. A bare run takes shared '
      'containers past --older-than and dedicated ones past a fixed 1 '
      'hour, since a dedicated container that old has outlived any '
      'plausible suite.';

  @override
  Future<int> run() async {
    // A bad duration is a usage mistake, so it exits like one — with the
    // message and the usage text, not a stack trace.
    final Duration olderThan;
    try {
      olderThan = parseDurationArg(argResults!.option('older-than')!);
    } on FormatException catch (e) {
      throw UsageException(e.message, usage);
    }

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

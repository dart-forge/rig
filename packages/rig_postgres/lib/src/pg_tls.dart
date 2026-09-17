import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';

/// Ask for a server certificate rig generates itself.
final class PgTls {
  const PgTls.selfSigned({
    this.commonName = 'localhost',
    this.validFor = const Duration(days: 3650),
  });

  final String commonName;

  /// Long by default: this certificate exists so a test can speak TLS, and an
  /// expiry is one more thing to debug years from now.
  final Duration validFor;
}

/// Where the generated certificate and key ended up.
final class PgTlsMaterial {
  const PgTlsMaterial({required this.certificate, required this.privateKey});

  final File certificate;
  final File privateKey;
}

/// openssl is not on this machine.
final class OpensslMissing extends RigException {
  const OpensslMissing({required this.detail});

  final String detail;

  @override
  String get message =>
      'TLS needs openssl to generate a test certificate, and running it '
      'failed: $detail\n\n'
      'Install openssl, or ask for a Postgres without TLS.';
}

/// openssl ran and refused.
final class OpensslFailed extends RigException {
  const OpensslFailed({required this.output});

  final String output;

  @override
  String get message =>
      'openssl could not generate a test certificate:\n$output';
}

/// The certificate and key for [tls], generating them if this machine does not
/// have them yet.
///
/// Cached rather than regenerated because a mount is hashed by content: a fresh
/// certificate every run would mean a fresh container every run, and nothing
/// would ever be shared.
///
/// Synchronous on purpose. `usePostgres` has to hand a finished spec to
/// `useContainer` at declaration time, before any `setUpAll` exists to await
/// anything in — so the paths have to be known by then. It costs one openssl
/// run on a machine that has never generated this material, and a file
/// existence check on every run after that.
PgTlsMaterial ensureTlsMaterial(
  PgTls tls, {
  required StateDir stateDir,
  ProcessResult Function(String, List<String>)? run,
}) {
  final dir = Directory(p.join(stateDir.certsDir.path, _fingerprintOf(tls)));
  final certificate = File(p.join(dir.path, 'server.crt'));
  final privateKey = File(p.join(dir.path, 'server.key'));

  if (certificate.existsSync() && privateKey.existsSync()) {
    return PgTlsMaterial(certificate: certificate, privateKey: privateKey);
  }

  dir.createSync(recursive: true);
  final runner = run ?? _runOpenssl;
  final ProcessResult result;
  try {
    result = runner('openssl', [
      'req',
      '-new',
      '-x509',
      '-nodes',
      '-days',
      '${tls.validFor.inDays}',
      '-subj',
      '/CN=${tls.commonName}',
      '-out',
      certificate.path,
      '-keyout',
      privateKey.path,
    ]);
  } on ProcessException catch (e) {
    _clear(dir);
    throw OpensslMissing(detail: e.message);
  }

  if (result.exitCode != 0 ||
      !certificate.existsSync() ||
      !privateKey.existsSync()) {
    // A half-written cache is worse than none: it would be mounted, the server
    // would refuse to start, and nothing would say why.
    _clear(dir);
    throw OpensslFailed(
      output: [result.stderr, result.stdout].join('\n').trim(),
    );
  }

  return PgTlsMaterial(certificate: certificate, privateKey: privateKey);
}

/// Everything about [tls] that changes the material it produces.
String _fingerprintOf(PgTls tls) {
  final digest = sha256.convert(
    utf8.encode('cn=${tls.commonName}|days=${tls.validFor.inDays}'),
  );
  return digest.toString().substring(0, 16);
}

void _clear(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Nothing to undo if it cannot be removed.
  }
}

ProcessResult _runOpenssl(String exe, List<String> args) =>
    Process.runSync(exe, args);

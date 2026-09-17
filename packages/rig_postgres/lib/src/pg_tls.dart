import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';

final Random _tokens = Random();

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

/// [PgTls] asked for something openssl cannot turn into a valid certificate.
final class InvalidPgTls extends RigException {
  const InvalidPgTls({required this.detail});

  final String detail;

  @override
  String get message => 'This TLS certificate cannot be generated: $detail';
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
///
/// Safe against two isolates racing to generate the same material on a fresh
/// machine: `withExclusiveLock` is async and this call is deliberately not,
/// so generation happens into a private temporary directory and only the
/// final `renameSync` into the shared, fingerprinted path is visible to a
/// concurrent caller. Two callers can each run openssl, but only one
/// directory ever lands at the shared path, and it is always a complete one
/// — never a certificate from one attempt paired with a key from another.
PgTlsMaterial ensureTlsMaterial(
  PgTls tls, {
  required StateDir stateDir,
  ProcessResult Function(String, List<String>)? run,
}) {
  _validate(tls);

  final dir = Directory(p.join(stateDir.certsDir.path, _fingerprintOf(tls)));
  final certificate = File(p.join(dir.path, 'server.crt'));
  final privateKey = File(p.join(dir.path, 'server.key'));

  if (certificate.existsSync() && privateKey.existsSync()) {
    return PgTlsMaterial(certificate: certificate, privateKey: privateKey);
  }

  dir.parent.createSync(recursive: true);
  final tmpDir = Directory(
    p.join(
      dir.parent.path,
      '.tmp-${_tokens.nextInt(1 << 32).toRadixString(16)}',
    ),
  );
  tmpDir.createSync(recursive: true);
  final tmpCertificate = File(p.join(tmpDir.path, 'server.crt'));
  final tmpPrivateKey = File(p.join(tmpDir.path, 'server.key'));

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
      tmpCertificate.path,
      '-keyout',
      tmpPrivateKey.path,
    ]);
  } on ProcessException catch (e) {
    _clear(tmpDir);
    throw OpensslMissing(detail: e.message);
  }

  if (result.exitCode != 0 ||
      !tmpCertificate.existsSync() ||
      !tmpPrivateKey.existsSync()) {
    // A half-written attempt is worse than none: it would be mounted, the
    // server would refuse to start, and nothing would say why. Only the
    // temporary directory is ever discarded here — never the shared one,
    // which another caller may already have finished writing.
    _clear(tmpDir);
    throw OpensslFailed(
      output: [result.stderr, result.stdout].join('\n').trim(),
    );
  }

  try {
    tmpDir.renameSync(dir.path);
  } on FileSystemException {
    // Another caller's renameSync won the race. What is now at the shared
    // path is a complete pair from whichever caller got there first — never
    // a mix of this attempt's certificate and someone else's key, because
    // each attempt only ever writes into its own temporary directory.
    _clear(tmpDir);
  }

  return PgTlsMaterial(certificate: certificate, privateKey: privateKey);
}

/// Rejects what openssl would otherwise fail on, or silently mishandle, with
/// a message that names the actual problem rather than surfacing openssl's.
void _validate(PgTls tls) {
  if (tls.validFor.inDays < 1) {
    throw InvalidPgTls(
      detail:
          'validFor must be at least a day (was ${tls.validFor}). '
          'openssl -days truncates anything shorter to 0, which it refuses '
          'to sign a certificate for.',
    );
  }
  if (tls.commonName.contains('/')) {
    throw InvalidPgTls(
      detail:
          "commonName must not contain '/' (was '${tls.commonName}'). "
          "openssl's -subj takes '/' as the separator between subject "
          'fields, so one inside the name corrupts the subject it builds.',
    );
  }
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

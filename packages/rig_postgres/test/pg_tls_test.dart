import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';
import 'package:rig_postgres/src/pg_tls.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StateDir state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rig_tls_');
    state = StateDir(tmp)..ensure();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('generates once and then reuses what it generated', () async {
    var runs = 0;
    ProcessResult fakeOpenssl(String exe, List<String> args) {
      runs++;
      // Stand in for openssl by writing the two files it would have written.
      final out = args[args.indexOf('-out') + 1];
      final key = args[args.indexOf('-keyout') + 1];
      File(out).writeAsStringSync('CERT');
      File(key).writeAsStringSync('KEY');
      return ProcessResult(0, 0, '', '');
    }

    const tls = PgTls.selfSigned();
    final first = ensureTlsMaterial(tls, stateDir: state, run: fakeOpenssl);
    final second = ensureTlsMaterial(tls, stateDir: state, run: fakeOpenssl);

    expect(
      runs,
      1,
      reason:
          'regenerating would change the spec hash every '
          'run and no container would ever be shared',
    );
    expect(first.certificate.path, second.certificate.path);
    expect(first.certificate.readAsStringSync(), 'CERT');
  });

  test('a different subject gets its own material', () {
    ProcessResult fakeOpenssl(String exe, List<String> args) {
      File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT');
      File(args[args.indexOf('-keyout') + 1]).writeAsStringSync('KEY');
      return ProcessResult(0, 0, '', '');
    }

    final a = ensureTlsMaterial(
      const PgTls.selfSigned(),
      stateDir: state,
      run: fakeOpenssl,
    );
    final b = ensureTlsMaterial(
      const PgTls.selfSigned(commonName: 'other.example'),
      stateDir: state,
      run: fakeOpenssl,
    );

    expect(a.certificate.path, isNot(b.certificate.path));
  });

  test('lives under the state directory, not the system temp', () {
    ProcessResult fakeOpenssl(String exe, List<String> args) {
      File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT');
      File(args[args.indexOf('-keyout') + 1]).writeAsStringSync('KEY');
      return ProcessResult(0, 0, '', '');
    }

    final material = ensureTlsMaterial(
      const PgTls.selfSigned(),
      stateDir: state,
      run: fakeOpenssl,
    );

    expect(material.certificate.path, startsWith(state.certsDir.path));
  });

  test('says openssl is missing rather than failing obscurely', () {
    ProcessResult noOpenssl(String exe, List<String> args) =>
        throw ProcessException(exe, args, 'No such file or directory', 2);

    expect(
      () => ensureTlsMaterial(
        const PgTls.selfSigned(),
        stateDir: state,
        run: noOpenssl,
      ),
      throwsA(
        isA<OpensslMissing>().having(
          (e) => e.message,
          'message',
          allOf(contains('openssl'), contains('TLS')),
        ),
      ),
    );
  });

  test('reports what openssl said when it fails', () {
    ProcessResult failing(String exe, List<String> args) =>
        ProcessResult(0, 1, '', 'unknown option -bogus');

    expect(
      () => ensureTlsMaterial(
        const PgTls.selfSigned(),
        stateDir: state,
        run: failing,
      ),
      throwsA(
        isA<RigException>().having(
          (e) => e.message,
          'message',
          contains('unknown option'),
        ),
      ),
    );
  });

  test(
    'a caller that loses the rename race keeps the winner intact, not a mix',
    () {
      // Discover the shared, fingerprinted destination first, the same way a
      // normal run would, then clear it so the race can be staged against a
      // known path.
      ProcessResult discover(String exe, List<String> args) {
        File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT');
        File(args[args.indexOf('-keyout') + 1]).writeAsStringSync('KEY');
        return ProcessResult(0, 0, '', '');
      }

      const tls = PgTls.selfSigned();
      final destination = ensureTlsMaterial(
        tls,
        stateDir: state,
        run: discover,
      ).certificate.parent;
      destination.deleteSync(recursive: true);

      // Models two isolates racing on a fresh machine: both see no cache and
      // both run openssl. This fake stands in for that interleaving —
      // while this caller's own attempt is still running, a concurrent
      // caller finishes first and renames its (different) material into the
      // shared destination.
      ProcessResult fakeOpenssl(String exe, List<String> args) {
        destination.createSync(recursive: true);
        File(p.join(destination.path, 'server.crt'))
            .writeAsStringSync('CERT_WINNER');
        File(p.join(destination.path, 'server.key'))
            .writeAsStringSync('KEY_WINNER');

        // This attempt's own material, written only to its own temporary
        // directory — never directly to the shared destination.
        File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT_LOSER');
        File(args[args.indexOf('-keyout') + 1]).writeAsStringSync('KEY_LOSER');
        return ProcessResult(0, 0, '', '');
      }

      final material = ensureTlsMaterial(
        tls,
        stateDir: state,
        run: fakeOpenssl,
      );

      // The pair actually mounted is the winner's, whole and matched — never
      // this caller's own certificate or key, and never one of each.
      expect(material.certificate.readAsStringSync(), 'CERT_WINNER');
      expect(material.privateKey.readAsStringSync(), 'KEY_WINNER');

      // Nothing but the winner's own directory is left in the certs dir:
      // this caller's temporary directory was discarded, not left to litter
      // the cache.
      expect(
        state.certsDir.listSync().whereType<Directory>().map((d) => d.path),
        [destination.path],
      );
    },
  );

  test('rejects a validFor shorter than a day', () {
    // openssl -days truncates a fraction of a day to 0, which it refuses to
    // sign a certificate for — this rejects it up front with a message that
    // names the actual problem instead.
    expect(
      () => ensureTlsMaterial(
        const PgTls.selfSigned(validFor: Duration(hours: 1)),
        stateDir: state,
      ),
      throwsA(
        isA<InvalidPgTls>().having(
          (e) => e.message,
          'message',
          contains('validFor'),
        ),
      ),
    );
  });

  test('rejects a commonName containing a slash', () {
    // openssl's -subj takes '/' as the field separator, so a commonName
    // containing one corrupts the subject it builds instead of failing
    // loudly.
    expect(
      () => ensureTlsMaterial(
        const PgTls.selfSigned(commonName: 'evil/CN=other'),
        stateDir: state,
      ),
      throwsA(
        isA<InvalidPgTls>().having(
          (e) => e.message,
          'message',
          contains('commonName'),
        ),
      ),
    );
  });

  test('does not leave half-written material behind on failure', () {
    var attempt = 0;
    ProcessResult flaky(String exe, List<String> args) {
      attempt++;
      if (attempt == 1) {
        // Wrote the certificate, then died before the key.
        File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT');
        return ProcessResult(0, 1, '', 'died halfway');
      }
      File(args[args.indexOf('-out') + 1]).writeAsStringSync('CERT2');
      File(args[args.indexOf('-keyout') + 1]).writeAsStringSync('KEY2');
      return ProcessResult(0, 0, '', '');
    }

    const tls = PgTls.selfSigned();
    expect(
      () => ensureTlsMaterial(tls, stateDir: state, run: flaky),
      throwsA(anything),
    );

    // A cached half is worse than no cache: it would be mounted and the server
    // would refuse to start, every run, with nothing to explain why.
    final second = ensureTlsMaterial(tls, stateDir: state, run: flaky);
    expect(second.certificate.readAsStringSync(), 'CERT2');
  });
}

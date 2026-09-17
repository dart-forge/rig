import 'dart:io';

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

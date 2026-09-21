/// A MySQL container for your Dart tests.
library;

export 'src/mysql_auth.dart' show MySqlAuth;
export 'src/mysql_exec.dart' show UnsafeMySqlIdentifier;
export 'src/mysql_lease.dart';
export 'src/mysql_spec.dart';
export 'src/mysql_tls.dart' show MySqlTls, NoTls, ServerDefaultTls;
export 'src/suite_database.dart'
    show SuiteDatabaseNotCreated, SuiteMarkerNotWritten;
export 'src/testing.dart' show AuthConfirmationFailed, MySqlIsolation, useMySql;

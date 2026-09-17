/// A Redis container for your Dart tests.
library;

export 'src/redis_lease.dart';
export 'src/redis_spec.dart';
export 'src/suite_index.dart'
    show RedisDatabasesExhausted, RedisIndexNotFlushed;
export 'src/testing.dart' show RedisIsolation, useRedis;

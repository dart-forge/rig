import 'dart:convert';
import 'dart:typed_data';

import 'package:rig/src/engine/log_frames.dart';
import 'package:test/test.dart';

/// Builds one Docker log frame: stream type, 3 padding bytes, big-endian
/// length, then the payload.
Uint8List frame(int stream, String payload) {
  final body = utf8.encode(payload);
  final out = BytesBuilder()
    ..addByte(stream)
    ..add([0, 0, 0])
    ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
    ..add(body);
  return out.toBytes();
}

void main() {
  test('reads a single stdout frame', () {
    expect(demuxLogFrames(frame(1, 'hello\n')), 'hello\n');
  });

  test('concatenates consecutive frames in order', () {
    final bytes = [...frame(1, 'one\n'), ...frame(1, 'two\n')];

    expect(demuxLogFrames(bytes), 'one\ntwo\n');
  });

  test(
    'keeps stderr alongside stdout: a failure reason is usually on stderr',
    () {
      final bytes = [...frame(1, 'starting\n'), ...frame(2, 'FATAL: nope\n')];

      expect(demuxLogFrames(bytes), 'starting\nFATAL: nope\n');
    },
  );

  test('handles a payload longer than 255 bytes', () {
    final long = 'x' * 1000;

    expect(demuxLogFrames(frame(1, '$long\n')), '$long\n');
  });

  test('returns empty for empty input', () {
    expect(demuxLogFrames(const []), isEmpty);
  });

  test('decodes multi-byte utf8 split across nothing', () {
    expect(demuxLogFrames(frame(1, 'ログ\n')), 'ログ\n');
  });

  test('stops cleanly on a truncated header rather than throwing', () {
    // Docker can cut the stream mid-frame when the container is removed.
    final bytes = [...frame(1, 'kept\n'), 1, 0, 0];

    expect(demuxLogFrames(bytes), 'kept\n');
  });

  test('stops cleanly on a truncated payload', () {
    final full = frame(1, 'kept\n');
    final truncated = [...full, ...frame(1, 'lost').sublist(0, 10)];

    expect(demuxLogFrames(truncated), 'kept\n');
  });

  test('falls back to raw text when the input is not framed at all', () {
    // A TTY container returns unframed output. Better to show it than to
    // show nothing.
    final raw = utf8.encode('plain output without frames\n');

    expect(demuxLogFrames(raw), contains('plain output'));
  });
}

import 'dart:convert';
import 'dart:typed_data';

/// Turn Docker's multiplexed log stream into text.
///
/// A container without a TTY returns its output as frames:
///
/// ```
/// [1 byte stream][3 bytes padding][4 bytes big-endian length][payload]
/// ```
///
/// stdout (1) and stderr (2) are both kept, in arrival order: the reason a
/// container never became usable is usually on stderr, and separating the two
/// would lose the interleaving that makes a log readable.
///
/// A truncated tail stops the walk instead of throwing — Docker cuts the
/// stream when a container goes away mid-read, and a partial log is still
/// worth showing. Input that is not framed at all is returned as text, since
/// a TTY container produces exactly that.
String demuxLogFrames(List<int> bytes) {
  if (bytes.isEmpty) return '';

  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  final out = BytesBuilder();

  var offset = 0;
  var sawFrame = false;

  while (offset + 8 <= data.length) {
    final stream = data[offset];
    if (stream > 2 ||
        data[offset + 1] != 0 ||
        data[offset + 2] != 0 ||
        data[offset + 3] != 0) {
      // Not a header. Either unframed output, or we lost sync.
      break;
    }

    final length = view.getUint32(offset + 4);
    final start = offset + 8;
    if (start + length > data.length) break; // truncated payload

    out.add(Uint8List.sublistView(data, start, start + length));
    offset = start + length;
    sawFrame = true;
  }

  if (!sawFrame) return _decode(data);
  return _decode(out.toBytes());
}

String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

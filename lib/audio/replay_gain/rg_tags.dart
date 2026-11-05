import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Replay Gain values found in an audio file's tags. Every field is null when
/// the file does not carry it.
class ReplayGainTags {
  const ReplayGainTags({
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  static const empty = ReplayGainTags();

  final double? trackGainDb;
  final double? trackPeak;
  final double? albumGainDb;
  final double? albumPeak;

  bool get isEmpty =>
      trackGainDb == null &&
      trackPeak == null &&
      albumGainDb == null &&
      albumPeak == null;

  @override
  String toString() =>
      'ReplayGainTags(trackGain: $trackGainDb, '
      'trackPeak: $trackPeak, albumGain: $albumGainDb, albumPeak: $albumPeak)';
}

const _headBytes = 256 * 1024;
const _maxMoovBytes = 16 * 1024 * 1024;
const _maxTagBytes = 4 * 1024 * 1024;
const _maxAtomWalk = 1000;

/// Bytes from the file start needed to hold the whole ID3 tag or FLAC
/// metadata section (capped at 4 MiB); tags often follow large cover art.
Future<int> _tagExtent(RandomAccessFile raf, Uint8List head, int length) async {
  int cap(int n) {
    final c = n < _maxTagBytes ? n : _maxTagBytes;
    return c < length ? c : length;
  }

  if (head.length >= 10 && _ascii(head, 0, 3) == 'ID3') {
    return cap(10 + _syncsafe(head, 6));
  }
  if (head.length >= 4 && _ascii(head, 0, 4) == 'fLaC') {
    var pos = 4;
    for (var i = 0; i < _maxAtomWalk && pos + 4 <= length; i++) {
      await raf.setPosition(pos);
      final h = await raf.read(4);
      if (h.length < 4) break;
      final size = (h[1] << 16) | (h[2] << 8) | h[3];
      pos += 4 + size;
      if ((h[0] & 0x80) != 0) break;
      if (pos >= _maxTagBytes) break;
    }
    return cap(pos);
  }
  return head.length;
}

/// Reads Replay Gain tags from [path]. Never throws; any error yields
/// [ReplayGainTags.empty].
Future<ReplayGainTags> readReplayGainTags(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    var head = await raf.read(_headBytes < length ? _headBytes : length);
    final needed = await _tagExtent(raf, head, length);
    if (needed > head.length) {
      await raf.setPosition(0);
      head = await raf.read(needed);
    }
    var tags = parseReplayGainTags(head);
    if (tags.isEmpty && _isMp4(head)) {
      final moov = await _findMoov(raf, length);
      if (moov != null) tags = parseReplayGainTags(moov);
    }
    return tags;
  } catch (_) {
    return ReplayGainTags.empty;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

/// Parses Replay Gain tags from the leading bytes of a file (ID3v2, FLAC,
/// Ogg Vorbis/Opus, or MP4 atoms). Pure; never throws.
ReplayGainTags parseReplayGainTags(Uint8List head) {
  try {
    final fields = <String, String>{};
    final opus = <String, double>{};
    _collect(head, fields, opus);
    return _build(fields, opus);
  } catch (_) {
    return ReplayGainTags.empty;
  }
}

bool _isMp4(Uint8List b) => b.length >= 8 && _ascii(b, 4, 4) == 'ftyp';

String _ascii(Uint8List b, int off, int len) =>
    off + len > b.length ? '' : String.fromCharCodes(b, off, off + len);

void _collect(
  Uint8List b,
  Map<String, String> fields,
  Map<String, double> opus,
) {
  if (b.length < 8) return;
  if (_ascii(b, 0, 3) == 'ID3') {
    final end = _parseId3(b, fields);
    if (fields.isEmpty && end != null && end + 4 <= b.length) {
      // Some FLAC files carry a leading ID3 block.
      if (_ascii(b, end, 4) == 'fLaC') {
        _parseFlac(Uint8List.sublistView(b, end), fields);
      }
    }
  } else if (_ascii(b, 0, 4) == 'fLaC') {
    _parseFlac(b, fields);
  } else if (_ascii(b, 0, 4) == 'OggS') {
    _parseOgg(b, fields, opus);
  } else {
    _parseAtoms(b, 0, b.length, fields, 0);
  }
}

ReplayGainTags _build(Map<String, String> f, Map<String, double> opus) {
  double? num(String key) {
    final v = f[key];
    if (v == null) return null;
    final m = RegExp(r'[-+]?\d+(?:\.\d+)?').firstMatch(v);
    return m == null ? null : double.tryParse(m.group(0)!);
  }

  return ReplayGainTags(
    trackGainDb: num('replaygain_track_gain') ?? opus['track'],
    trackPeak: num('replaygain_track_peak'),
    albumGainDb: num('replaygain_album_gain') ?? opus['album'],
    albumPeak: num('replaygain_album_peak'),
  );
}

void _put(Map<String, String> fields, String key, String value) {
  final k = key.trim().toLowerCase();
  if (k.startsWith('replaygain_')) fields.putIfAbsent(k, () => value.trim());
}

// ---------------------------------------------------------------- ID3v2

int _syncsafe(Uint8List b, int o) =>
    ((b[o] & 0x7f) << 21) |
    ((b[o + 1] & 0x7f) << 14) |
    ((b[o + 2] & 0x7f) << 7) |
    (b[o + 3] & 0x7f);

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Returns the offset just past the tag, or null if the header is invalid.
Uint8List _deunsync(Uint8List d) {
  final out = <int>[];
  for (var i = 0; i < d.length; i++) {
    out.add(d[i]);
    if (d[i] == 0xff && i + 1 < d.length && d[i + 1] == 0) i++;
  }
  return Uint8List.fromList(out);
}

int? _parseId3(Uint8List b, Map<String, String> fields) {
  if (b.length < 10) return null;
  final version = b[3];
  if (version < 2 || version > 4) return null;
  final flags = b[5];
  final tagEnd = 10 + _syncsafe(b, 6);
  var end = tagEnd < b.length ? tagEnd : b.length;
  final tagUnsync = (flags & 0x80) != 0;
  final origEnd = tagEnd;
  if (tagUnsync && version != 4) {
    // v2.2 / v2.3: the whole tag body is unsynchronised.
    b = Uint8List.fromList([
      ...b.sublist(0, 10),
      ..._deunsync(b.sublist(10, end)),
    ]);
    end = b.length;
  }
  var pos = 10;
  if (version >= 3 && (flags & 0x40) != 0 && pos + 4 <= end) {
    pos += version == 4 ? _syncsafe(b, pos) : _be32(b, pos) + 4;
  }
  final idLen = version == 2 ? 3 : 4;
  final headerLen = version == 2 ? 6 : 10;
  while (pos + headerLen <= end) {
    if (b[pos] == 0) break; // padding
    final id = _ascii(b, pos, idLen);
    final int size;
    if (version == 2) {
      size = (b[pos + 3] << 16) | (b[pos + 4] << 8) | b[pos + 5];
    } else if (version == 3) {
      size = _be32(b, pos + 4);
    } else {
      size = _syncsafe(b, pos + 4);
    }
    final start = pos + headerLen;
    if (size < 0 || start + size > end) break; // truncated frame
    if (id == 'TXXX' || id == 'TXX') {
      var body = Uint8List.sublistView(b, start, start + size);
      if (version == 4 && (tagUnsync || (b[pos + 9] & 0x02) != 0)) {
        body = _deunsync(body);
      }
      // v2.4 data length indicator (format flag 0x01): four bytes ahead of the
      // frame's data.
      if (version == 4 && (b[pos + 9] & 0x01) != 0 && body.length > 4) {
        body = Uint8List.sublistView(body, 4);
      }
      _parseTxxx(body, fields);
    }
    pos = start + size;
  }
  return origEnd;
}

void _parseTxxx(Uint8List body, Map<String, String> fields) {
  if (body.length < 2) return;
  final enc = body[0];
  final wide = enc == 1 || enc == 2;
  const i = 1;
  var termAt = -1;
  if (wide) {
    for (var j = i; j + 1 < body.length; j += 2) {
      if (body[j] == 0 && body[j + 1] == 0) {
        termAt = j;
        break;
      }
    }
  } else {
    termAt = body.indexOf(0, i);
  }
  if (termAt < 0) return;
  final desc = _decodeText(enc, Uint8List.sublistView(body, i, termAt));
  final valueStart = termAt + (wide ? 2 : 1);
  if (valueStart > body.length) return;
  var value = _decodeText(enc, Uint8List.sublistView(body, valueStart));
  final nul = value.indexOf('\u0000');
  if (nul >= 0) value = value.substring(0, nul);
  _put(fields, desc, value);
}

String _decodeText(int enc, Uint8List b) {
  switch (enc) {
    case 1:
    case 2:
      var bigEndian = enc == 2;
      var i = 0;
      if (enc == 1 && b.length >= 2) {
        if (b[0] == 0xfe && b[1] == 0xff) {
          bigEndian = true;
          i = 2;
        } else if (b[0] == 0xff && b[1] == 0xfe) {
          i = 2;
        }
      }
      final units = <int>[];
      for (; i + 1 < b.length; i += 2) {
        units.add(bigEndian ? (b[i] << 8) | b[i + 1] : (b[i + 1] << 8) | b[i]);
      }
      return String.fromCharCodes(units);
    case 3:
      return utf8.decode(b, allowMalformed: true);
    default:
      return latin1.decode(b);
  }
}

// ------------------------------------------------------- Vorbis comments

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// Parses a Vorbis-style comment block (vendor + user comments) starting at
/// [offset]. Throws on truncation.
List<String> _vorbisComments(Uint8List b, int offset) {
  var pos = offset;
  final vendorLen = _le32(b, pos);
  pos += 4 + vendorLen;
  final count = _le32(b, pos);
  pos += 4;
  final out = <String>[];
  // On truncation keep the comments parsed so far.
  for (var i = 0; i < count; i++) {
    if (pos + 4 > b.length) break;
    final len = _le32(b, pos);
    pos += 4;
    if (len < 0 || pos + len > b.length) break;
    out.add(
      utf8.decode(
        Uint8List.sublistView(b, pos, pos + len),
        allowMalformed: true,
      ),
    );
    pos += len;
  }
  return out;
}

void _putComments(List<String> comments, Map<String, String> fields) {
  for (final c in comments) {
    final eq = c.indexOf('=');
    if (eq > 0) _put(fields, c.substring(0, eq), c.substring(eq + 1));
  }
}

// ------------------------------------------------------------------ FLAC

void _parseFlac(Uint8List b, Map<String, String> fields) {
  var pos = 4;
  while (pos + 4 <= b.length) {
    final header = b[pos];
    final isLast = (header & 0x80) != 0;
    final type = header & 0x7f;
    final size = (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
    final start = pos + 4;
    if (start + size > b.length) return;
    if (type == 4) {
      _putComments(
        _vorbisComments(Uint8List.sublistView(b, start, start + size), 0),
        fields,
      );
      return;
    }
    if (isLast) return;
    pos = start + size;
  }
}

// ------------------------------------------------------------------- Ogg

void _parseOgg(
  Uint8List b,
  Map<String, String> fields,
  Map<String, double> opus,
) {
  var pos = 0;
  final current = <int>[];
  var packetsSeen = 0;
  while (pos + 27 <= b.length && _ascii(b, pos, 4) == 'OggS') {
    final nSegs = b[pos + 26];
    final tableStart = pos + 27;
    if (tableStart + nSegs > b.length) return;
    var dataPos = tableStart + nSegs;
    for (var s = 0; s < nSegs; s++) {
      final segLen = b[tableStart + s];
      if (dataPos + segLen > b.length) {
        // Cut by the head (cover art ahead of the audio): the fields come
        // before any picture, so read what there is of the packet.
        current.addAll(Uint8List.sublistView(b, dataPos));
        try {
          _handleOggPacket(Uint8List.fromList(current), fields, opus);
        } catch (_) {}
        return;
      }
      current.addAll(Uint8List.sublistView(b, dataPos, dataPos + segLen));
      dataPos += segLen;
      if (segLen < 255) {
        final packet = Uint8List.fromList(current);
        current.clear();
        packetsSeen++;
        if (_handleOggPacket(packet, fields, opus)) return;
        if (packetsSeen > 4) return;
      }
    }
    pos = dataPos;
  }
}

/// Returns true once the comment packet has been consumed.
bool _handleOggPacket(
  Uint8List p,
  Map<String, String> fields,
  Map<String, double> opus,
) {
  if (p.length > 7 && p[0] == 3 && _ascii(p, 1, 6) == 'vorbis') {
    _putComments(_vorbisComments(p, 7), fields);
    return true;
  }
  if (p.length > 8 && _ascii(p, 0, 8) == 'OpusTags') {
    for (final c in _vorbisComments(p, 8)) {
      final eq = c.indexOf('=');
      if (eq <= 0) continue;
      final key = c.substring(0, eq).trim().toLowerCase();
      final value = c.substring(eq + 1);
      final q = int.tryParse(value.trim());
      if (q != null) {
        // R128 gains are Q7.8 fixed point relative to -23 LUFS; Replay Gain
        // targets -18 LUFS, hence the +5 dB.
        if (key == 'r128_track_gain') opus['track'] = q / 256.0 + 5.0;
        if (key == 'r128_album_gain') opus['album'] = q / 256.0 + 5.0;
      }
      _put(fields, key, value);
    }
    return true;
  }
  return false;
}

// ------------------------------------------------------------------- MP4

const _containers = {'moov', 'udta', 'ilst'};

void _parseAtoms(
  Uint8List b,
  int start,
  int end,
  Map<String, String> fields,
  int depth,
) {
  if (depth > 8) return;
  var pos = start;
  while (pos + 8 <= end) {
    var size = _be32(b, pos);
    final type = _ascii(b, pos + 4, 4);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > end) return;
      size = (_be32(b, pos + 8) << 32) | _be32(b, pos + 12);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header) return;
    final atomEnd = pos + size < end ? pos + size : end; // clamp truncation
    final bodyStart = pos + header;
    if (_containers.contains(type)) {
      _parseAtoms(b, bodyStart, atomEnd, fields, depth + 1);
    } else if (type == 'meta') {
      _parseAtoms(b, bodyStart + 4, atomEnd, fields, depth + 1);
    } else if (type == '----') {
      _parseFreeForm(b, bodyStart, atomEnd, fields);
    }
    pos += size;
  }
}

void _parseFreeForm(
  Uint8List b,
  int start,
  int end,
  Map<String, String> fields,
) {
  String? name;
  String? value;
  var pos = start;
  while (pos + 8 <= end) {
    final size = _be32(b, pos);
    final type = _ascii(b, pos + 4, 4);
    if (size < 8) return;
    final atomEnd = pos + size < end ? pos + size : end;
    if (type == 'name' && pos + 12 <= atomEnd) {
      name = latin1.decode(Uint8List.sublistView(b, pos + 12, atomEnd));
    } else if (type == 'data' && pos + 16 <= atomEnd) {
      value = utf8.decode(
        Uint8List.sublistView(b, pos + 16, atomEnd),
        allowMalformed: true,
      );
    }
    pos += size;
  }
  if (name != null && value != null) _put(fields, name, value);
}

/// Walks top-level atoms in the file to find `moov` wherever it is.
Future<Uint8List?> _findMoov(RandomAccessFile raf, int length) async {
  var pos = 0;
  for (var n = 0; n < _maxAtomWalk && pos + 8 <= length; n++) {
    await raf.setPosition(pos);
    final h = await raf.read(16);
    if (h.length < 8) return null;
    var size = _be32(h, 0);
    final type = _ascii(h, 4, 4);
    if (size == 1) {
      if (h.length < 16) return null;
      size = (_be32(h, 8) << 32) | _be32(h, 12);
    } else if (size == 0) {
      size = length - pos;
    }
    if (size < 8) return null;
    if (type == 'moov') {
      final take = size < _maxMoovBytes ? size : _maxMoovBytes;
      final n = pos + take < length ? take : length - pos;
      await raf.setPosition(pos);
      return await raf.read(n);
    }
    pos += size;
  }
  return null;
}

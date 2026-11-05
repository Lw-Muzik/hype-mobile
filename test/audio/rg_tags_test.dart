import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eq_app/audio/replay_gain/rg_tags.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _u32be(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);
Uint8List _u32le(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _syncsafe(int v) => Uint8List.fromList([
  (v >> 21) & 0x7f,
  (v >> 14) & 0x7f,
  (v >> 7) & 0x7f,
  v & 0x7f,
]);
Uint8List _cat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

Uint8List _txxx(String desc, String value, {bool syncsafe = false}) {
  final body = _cat([
    [0],
    latin1.encode(desc),
    [0],
    latin1.encode(value),
  ]);
  return _cat([
    ascii.encode('TXXX'),
    syncsafe ? _syncsafe(body.length) : _u32be(body.length),
    [0, 0],
    body,
  ]);
}

Uint8List _id3(List<Uint8List> frames, {int version = 3}) {
  final payload = _cat(frames);
  return _cat([
    ascii.encode('ID3'),
    [version, 0, 0],
    _syncsafe(payload.length),
    payload,
  ]);
}

Uint8List _vorbisComments(List<String> comments, {String vendor = 'v'}) {
  final out = <int>[
    ..._u32le(vendor.length),
    ...ascii.encode(vendor),
    ..._u32le(comments.length),
  ];
  for (final c in comments) {
    final b = utf8.encode(c);
    out
      ..addAll(_u32le(b.length))
      ..addAll(b);
  }
  return Uint8List.fromList(out);
}

Uint8List _flac(List<String> comments) {
  final vc = _vorbisComments(comments);
  final streamInfo = Uint8List(34);
  return _cat([
    ascii.encode('fLaC'),
    [0, 0, 0, 34], // STREAMINFO, not last
    streamInfo,
    [
      0x84,
      0,
      (vc.length >> 8) & 0xff,
      vc.length & 0xff,
    ], // last, VORBIS_COMMENT
    vc,
  ]);
}

Uint8List _oggPage(Uint8List packet, int seq) {
  final segs = <int>[];
  var n = packet.length;
  while (n >= 255) {
    segs.add(255);
    n -= 255;
  }
  segs.add(n);
  return _cat([
    ascii.encode('OggS'),
    [0, seq == 0 ? 2 : 0],
    Uint8List(8),
    _u32le(1),
    _u32le(seq),
    Uint8List(4),
    [segs.length],
    segs,
    packet,
  ]);
}

Uint8List _atom(String type, List<int> body) =>
    _cat([_u32be(body.length + 8), ascii.encode(type), body]);

Uint8List _mp4Free(String name, String value) {
  final mean = _atom('mean', [0, 0, 0, 0, ...ascii.encode('com.apple.iTunes')]);
  final nm = _atom('name', [0, 0, 0, 0, ...ascii.encode(name)]);
  final data = _atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]);
  return _atom('----', [...mean, ...nm, ...data]);
}

Uint8List _mp4(String name, String value) {
  final ilst = _atom('ilst', _mp4Free(name, value));
  final meta = _atom('meta', [0, 0, 0, 0, ...ilst]);
  final udta = _atom('udta', meta);
  final moov = _atom('moov', udta);
  return _cat([_atom('ftyp', ascii.encode('M4A \x00\x00\x00\x00')), moov]);
}

Uint8List _unsync(List<int> d) {
  final o = <int>[];
  for (var i = 0; i < d.length; i++) {
    o.add(d[i]);
    if (d[i] == 0xff &&
        (i + 1 == d.length || d[i + 1] >= 0xe0 || d[i + 1] == 0)) {
      o.add(0);
    }
  }
  return Uint8List.fromList(o);
}

Uint8List _u64be(int v) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.big);

void main() {
  group('parseReplayGainTags', () {
    test('MP4 atom with size 0 runs to the end of the data', () {
      final ilst = _atom('ilst', _mp4Free('replaygain_track_gain', '-4.00 dB'));
      final meta = _atom('meta', [0, 0, 0, 0, ...ilst]);
      final udta = _atom('udta', meta);
      final moov = _cat([_u32be(0), ascii.encode('moov'), udta]);
      expect(
        parseReplayGainTags(_cat([_atom('ftyp', Uint8List(8)), moov]))
            .trackGainDb,
        -4.0,
      );
    });

    test('MP4 atom with 64-bit size', () {
      final ilst = _atom('ilst', _mp4Free('replaygain_track_gain', '-5.00 dB'));
      final meta = _atom('meta', [0, 0, 0, 0, ...ilst]);
      final udta = _atom('udta', meta);
      final moov = _cat([
        _u32be(1),
        ascii.encode('moov'),
        _u64be(udta.length + 16),
        udta,
      ]);
      expect(
        parseReplayGainTags(_cat([_atom('ftyp', Uint8List(8)), moov]))
            .trackGainDb,
        -5.0,
      );
    });

    test('ID3 frame claiming more bytes than present keeps earlier frames', () {
      final good = _txxx('replaygain_track_gain', '-1.50 dB');
      final bad = _cat([
        ascii.encode('TXXX'),
        _u32be(5000),
        [0, 0],
        [0, 65, 0, 66],
      ]);
      final t = parseReplayGainTags(_id3([good, bad]));
      expect(t.trackGainDb, -1.5);
    });

    test('unsynchronised ID3v2.3 tag with a UTF-16 TXXX', () {
      final body = _cat([
        [1, 0xff, 0xfe],
        [
          for (final c in 'replaygain_track_gain'.codeUnits) ...[c, 0],
        ],
        [0, 0],
        [0xff, 0xfe],
        [
          for (final c in '-9.25 dB'.codeUnits) ...[c, 0],
        ],
      ]);
      final frame = _cat([
        ascii.encode('TXXX'),
        _u32be(body.length),
        [0, 0],
        body,
      ]);
      final payload = _unsync(frame);
      expect(payload.length, greaterThan(frame.length));
      final tag = _cat([
        ascii.encode('ID3'),
        [3, 0, 0x80],
        _syncsafe(payload.length),
        payload,
      ]);
      expect(parseReplayGainTags(tag).trackGainDb, -9.25);
    });

    test('ID3v2.3 TXXX frames', () {
      final t = parseReplayGainTags(
        _id3([
          _txxx('replaygain_track_gain', '-6.54 dB'),
          _txxx('replaygain_track_peak', '0.988'),
          _txxx('replaygain_album_gain', '+1.20 dB'),
          _txxx('replaygain_album_peak', '1.05'),
        ]),
      );
      expect(t.trackGainDb, closeTo(-6.54, 1e-9));
      expect(t.trackPeak, closeTo(0.988, 1e-9));
      expect(t.albumGainDb, closeTo(1.2, 1e-9));
      expect(t.albumPeak, closeTo(1.05, 1e-9));
      expect(t.isEmpty, isFalse);
    });

    test('ID3v2.4 syncsafe frame sizes and UTF-16 text', () {
      final body = _cat([
        [1, 0xff, 0xfe],
        [
          for (final c in 'replaygain_track_gain'.codeUnits) ...[c, 0],
        ],
        [0, 0],
        [0xff, 0xfe],
        [
          for (final c in '-2.50 dB'.codeUnits) ...[c, 0],
        ],
      ]);
      final frame = _cat([
        ascii.encode('TXXX'),
        _syncsafe(body.length),
        [0, 0],
        body,
      ]);
      final t = parseReplayGainTags(_id3([frame], version: 4));
      expect(t.trackGainDb, closeTo(-2.5, 1e-9));
    });

    test('ID3v2.4 data length indicator is skipped before the TXXX body', () {
      final body = _txxx('replaygain_track_gain', '-4.25 dB').sublist(10);
      final frame = _cat([
        ascii.encode('TXXX'),
        _syncsafe(body.length + 4),
        [0, 1], // format flags: data length indicator present
        _syncsafe(body.length),
        body,
      ]);
      final t = parseReplayGainTags(_id3([frame], version: 4));
      expect(t.trackGainDb, closeTo(-4.25, 1e-9));
    });

    test('FLAC vorbis comment, keys case-insensitive', () {
      final t = parseReplayGainTags(
        _flac([
          'TITLE=x',
          'REPLAYGAIN_TRACK_GAIN=-3.00 dB',
          'replaygain_track_peak=0.5',
        ]),
      );
      expect(t.trackGainDb, -3.0);
      expect(t.trackPeak, 0.5);
    });

    test('Ogg Vorbis comment packet with album tags', () {
      final id = _oggPage(
        _cat([
          [1],
          ascii.encode('vorbis'),
          Uint8List(23),
        ]),
        0,
      );
      final comment = _oggPage(
        _cat([
          [3],
          ascii.encode('vorbis'),
          _vorbisComments([
            'REPLAYGAIN_ALBUM_GAIN=-8.25 dB',
            'REPLAYGAIN_ALBUM_PEAK=0.97',
          ]),
          [1],
        ]),
        1,
      );
      final t = parseReplayGainTags(_cat([id, comment]));
      expect(t.albumGainDb, closeTo(-8.25, 1e-9));
      expect(t.albumPeak, closeTo(0.97, 1e-9));
      expect(t.trackGainDb, isNull);
    });

    test('Ogg comment packet cut by the head still yields the early fields', () {
      final id = _oggPage(
        _cat([
          [1],
          ascii.encode('vorbis'),
          Uint8List(23),
        ]),
        0,
      );
      final picture = 'METADATA_BLOCK_PICTURE=${'A' * 50000}';
      final comment = _oggPage(
        _cat([
          [3],
          ascii.encode('vorbis'),
          _vorbisComments([
            'REPLAYGAIN_TRACK_GAIN=-5.50 dB',
            'REPLAYGAIN_TRACK_PEAK=0.88',
            picture,
          ]),
          [1],
        ]),
        1,
      );
      final whole = _cat([id, comment]);
      final head = Uint8List.sublistView(whole, 0, id.length + 20000);
      final t = parseReplayGainTags(head);
      expect(t.trackGainDb, closeTo(-5.5, 1e-9));
      expect(t.trackPeak, closeTo(0.88, 1e-9));
    });

    test('Opus R128_TRACK_GAIN converts to dB with +5 reference', () {
      final id = _oggPage(_cat([ascii.encode('OpusHead'), Uint8List(11)]), 0);
      final tags = _oggPage(
        _cat([
          ascii.encode('OpusTags'),
          _vorbisComments(['R128_TRACK_GAIN=-512']),
        ]),
        1,
      );
      final t = parseReplayGainTags(_cat([id, tags]));
      expect(t.trackGainDb, closeTo(3.0, 1e-9));
    });

    test('MP4 moov/udta/meta/ilst free-form atom', () {
      final t = parseReplayGainTags(_mp4('replaygain_track_gain', '-7.10 dB'));
      expect(t.trackGainDb, closeTo(-7.1, 1e-9));
    });

    test('garbage, empty and truncated input yield empty tags', () {
      expect(parseReplayGainTags(Uint8List(0)).isEmpty, isTrue);
      expect(
        parseReplayGainTags(Uint8List.fromList(List.filled(300, 7))).isEmpty,
        isTrue,
      );
      final full = _id3([_txxx('replaygain_track_gain', '-6.54 dB')]);
      expect(
        parseReplayGainTags(full.sublist(0, full.length - 6)).isEmpty,
        isTrue,
      );
      final flac = _flac(['REPLAYGAIN_TRACK_GAIN=-3 dB']);
      expect(() => parseReplayGainTags(flac.sublist(0, 60)), returnsNormally);
      final mp4 = _mp4('replaygain_track_gain', '-7.10 dB');
      expect(
        () => parseReplayGainTags(mp4.sublist(0, mp4.length - 5)),
        returnsNormally,
      );
    });
  });

  group('readReplayGainTags', () {
    test('finds a TXXX placed after a >256 KiB APIC frame', () async {
      final dir = await Directory.systemTemp.createTemp('rg');
      addTearDown(() => dir.delete(recursive: true));
      final apicBody = Uint8List(300 * 1024);
      final apic = _cat([
        ascii.encode('APIC'),
        _u32be(apicBody.length),
        [0, 0],
        apicBody,
      ]);
      final f = File('${dir.path}/a.mp3')
        ..writeAsBytesSync(
          _id3([apic, _txxx('replaygain_track_gain', '-6.54 dB')]),
        );
      expect(
        (await readReplayGainTags(f.path)).trackGainDb,
        closeTo(-6.54, 1e-9),
      );
    });

    test('reads a file and never throws on a missing one', () async {
      final dir = await Directory.systemTemp.createTemp('rg');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/a.flac')
        ..writeAsBytesSync(_flac(['REPLAYGAIN_TRACK_GAIN=-3.00 dB']));
      expect((await readReplayGainTags(f.path)).trackGainDb, -3.0);
      expect(
        (await readReplayGainTags('${dir.path}/nope.mp3')).isEmpty,
        isTrue,
      );
    });

    test('finds an MP4 moov atom placed after a large mdat', () async {
      final dir = await Directory.systemTemp.createTemp('rg');
      addTearDown(() => dir.delete(recursive: true));
      final mp4 = _mp4('replaygain_track_gain', '-7.10 dB');
      final ftyp = mp4.sublist(0, 16);
      final moov = mp4.sublist(16);
      final mdat = _atom('mdat', Uint8List(600 * 1024));
      final f = File('${dir.path}/a.m4a')
        ..writeAsBytesSync(_cat([ftyp, mdat, moov]));
      expect(
        (await readReplayGainTags(f.path)).trackGainDb,
        closeTo(-7.1, 1e-9),
      );
    });
  });
}

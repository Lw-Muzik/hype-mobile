import 'package:eq_app/audio/info/audio_info.dart';
import 'package:eq_app/audio/replay_gain/rg_tags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> ids(List<InfoStage> s) => [for (final x in s) x.id];

  test('nothing active gives no stages', () {
    expect(describeChain(), isEmpty);
  });

  test('stages come out in engine order', () {
    final s = describeChain(
      stemsActive: true,
      replayGainEnabled: true,
      replayGainDb: -6.2,
      replayGainSource: RgTagSource.track,
      headroomDb: -3,
      graphicEqEnabled: true,
      eqBandCount: 10,
      parametricPoints: 2,
      speakerEqEnabled: true,
      speakerProfile: 'Sony',
      toneEnabled: true,
      bassDb: 3,
      mbcEnabled: true,
      crossfeedEnabled: true,
      surroundEnabled: true,
      surroundIntensity: 0.6,
      reverbEnabled: true,
      reverbPreset: 'Hall',
      dvcRunning: true,
      dvcGainDb: -12,
      stereoExpand: 0.4,
      mono: true,
      balance: -0.5,
      limiterEnabled: true,
    );
    expect(ids(s), [
      'stems', 'input', 'speaker', 'graphic', 'parametric', 'tone', 'mbc',
      'crossfeed', 'surround', 'reverb', 'master', 'expand', 'mono',
      'balance', 'limiter',
    ]);
  });

  test('values are formatted', () {
    final s = describeChain(
      replayGainEnabled: true,
      replayGainDb: -6.24,
      replayGainSource: RgTagSource.album,
      headroomDb: -3,
      graphicEqEnabled: true,
      preampDb: 1.5,
      eqBandCount: 15,
      eqPreset: 'Rock',
      toneEnabled: true,
      bassDb: 4,
      trebleDb: 0,
      stereoExpand: 0.25,
      balance: 0.3,
      limiterEnabled: true,
      limiterReductionDb: 2.34,
    );
    String v(String id) => s.firstWhere((e) => e.id == id).value;
    expect(v('input'),
        'Replay Gain -6.2 dB (album) · Preamp +1.5 dB · Headroom -3 dB');
    expect(v('graphic'), '15 bands · Rock');
    expect(v('tone'), 'Bass +4 dB · Treble 0 dB');
    expect(v('expand'), '25%');
    expect(v('balance'), 'Right 30%');
    expect(v('limiter'), 'reducing 2.3 dB');
  });

  test('Replay Gain source line: untagged preamp and preferred fallback', () {
    expect(
      describeReplayGain(
          enabled: true, db: 2, source: RgTagSource.untagged),
      'Replay Gain +2 dB (untagged preamp)',
    );
    expect(
      describeReplayGain(enabled: true, db: 0, preferred: 'track'),
      'Replay Gain 0 dB (track preferred)',
    );
    expect(describeReplayGain(enabled: false, db: 3), isNull);
  });

  test('inactive and neutral stages are omitted', () {
    final s = describeChain(
      graphicEqEnabled: false,
      eqBandCount: 10,
      preampDb: 3, // gated by the EQ being on
      toneEnabled: true, // but both shelves at 0
      limiterEnabled: false,
      balance: 0,
      stereoExpand: 0,
    );
    expect(s, isEmpty);
  });

  test('Equalizer-only mode drops the Replay Gain line', () {
    final s = describeChain(
      eqOnly: true,
      replayGainEnabled: true,
      replayGainDb: -4,
      headroomDb: -3,
    );
    expect(s.single.value, 'Headroom -3 dB');
  });

  test('system-wide: one system stage, engine keeps parametric and effects', () {
    final s = describeChain(
      systemWide: true,
      replayGainEnabled: true,
      replayGainDb: -4,
      headroomDb: -3,
      graphicEqEnabled: true,
      eqBandCount: 10,
      preampDb: 2,
      parametricPoints: 1,
      toneEnabled: true,
      bassDb: 3,
      stereoExpand: 0.5,
      mono: true,
      balance: 1,
      reverbEnabled: true,
      limiterEnabled: true,
    );
    expect(ids(s), ['system', 'parametric', 'reverb', 'limiter']);
    expect(s.first.value,
        '10 bands · Preamp +2 dB · Headroom -3 dB · Bass +3 dB · Treble 0 dB · Limiter');
  });

  test('Equalizer-only with system-wide shows only the system stage', () {
    final s = describeChain(
      eqOnly: true,
      systemWide: true,
      graphicEqEnabled: true,
      eqBandCount: 15,
      headroomDb: -6,
      reverbEnabled: true,
      mbcEnabled: true,
      parametricPoints: 2,
    );
    expect(ids(s), ['system']);
  });

  test('preamp applies with the speaker EQ alone; speaker preamp shown', () {
    final s = describeChain(
      preampDb: -2,
      speakerEqEnabled: true,
      speakerProfile: 'Sony',
      speakerPreampDb: -4.5,
    );
    expect(s.firstWhere((e) => e.id == 'input').value,
        'Preamp -2 dB · Speaker preamp -4.5 dB');
    expect(s.firstWhere((e) => e.id == 'speaker').value,
        'Sony · preamp -4.5 dB');
  });

  test('output with No Equalizer/Tone drops graphic, parametric, tone, preamp',
      () {
    final s = describeChain(
      noEqTone: true,
      graphicEqEnabled: true,
      eqBandCount: 10,
      preampDb: 3,
      parametricPoints: 2,
      toneEnabled: true,
      bassDb: 3,
    );
    expect(s, isEmpty);
  });

  test('effective headroom: none under DVC or on a no-reduction output', () {
    expect(effectiveHeadroomDb(headroomDb: -6, dvcRunning: true, noHeadroomReduction: false), 0);
    expect(effectiveHeadroomDb(headroomDb: -6, dvcRunning: false, noHeadroomReduction: true), 0);
    expect(effectiveHeadroomDb(headroomDb: -6, dvcRunning: false, noHeadroomReduction: false), -6);
  });

  test('resolveRgSource routes like trackGainDbFor', () async {
    const tags = ReplayGainTags(trackGainDb: -5);
    final reads = <String>[];
    Future<ReplayGainTags> file(String p) async {
      reads.add('file');
      return tags;
    }

    Future<ReplayGainTags> native(String p) async {
      reads.add('native');
      return tags;
    }

    Future<RgTagSource> go(String path, {bool album = true}) => resolveRgSource(
        path: path, albumFirst: album, read: file, readNative: native);
    expect(await go('/a/b.mp3'), RgTagSource.track);
    expect(await go('ipod-library://item/1'), RgTagSource.track);
    expect(reads, ['file', 'native']);
    expect(await go('https://x/y'), RgTagSource.untagged);
    expect(reads.length, 2);
  });

  test('describeSource skips missing keys', () {
    expect(describeSource(null), isEmpty);
    final s = describeSource({
      'sampleRate': 44100,
      'channels': 2,
      'codec': 'AAC',
    });
    expect(s.map((e) => e.value), ['AAC', '44.1 kHz', 'Stereo']);
  });

  test('describeSource: pcm as Decoded format, codec from extension', () {
    final s = describeSource(
      {'sampleRate': 48000, 'channels': 2, 'pcm': 'PCM float'},
      path: '/m/a.FLAC',
    );
    expect(s.map((e) => e.title), [
      'Codec', 'Decoded format', 'Sample rate', 'Channels',
    ]);
    expect(s.first.value, 'FLAC');
    // A native codec wins; a stream has no extension label.
    expect(describeSource({'codec': 'AAC'}, path: '/a.mp3').single.value, 'AAC');
    expect(describeSource({'channels': 2}, path: 'https://x/a.mp3').length, 1);
    expect(codecFromPath('/a/b.m4a'), 'M4A');
  });
}

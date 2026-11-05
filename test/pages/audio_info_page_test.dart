import 'package:eq_app/audio/info/audio_info.dart';
import 'package:eq_app/pages/audio_info_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const data = AudioInfoData(
    processing: [
      InfoStage('graphic', 'Graphic EQ', '10 bands'),
      InfoStage('limiter', 'Limiter', 'On'),
    ],
    systemWide: false,
    eqOnly: false,
    route: 'Bluetooth · Buds',
    sourceKind: 'File',
  );

  testWidgets('renders sections and live limiter reduction', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AudioInfoView(
        data: data,
        infoSource: () async => {
          'sampleRate': 48000,
          'channels': 2,
          'codec': 'FLAC',
          'limiterReductionDb': 3.21,
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Processing'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('48 kHz'), findsOneWidget);
    expect(find.text('10 bands'), findsOneWidget);
    expect(find.text('reducing 3.2 dB'), findsOneWidget);
    expect(find.text('Bluetooth · Buds'), findsOneWidget);
  });

  testWidgets('polls every 250 ms and stops on dispose', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: AudioInfoView(
        data: data,
        infoSource: () async {
          calls++;
          return null;
        },
      ),
    ));
    await tester.pump();
    final first = calls;
    expect(first, 1);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, first + 2);

    await tester.pumpWidget(const SizedBox());
    final after = calls;
    await tester.pump(const Duration(seconds: 1));
    expect(calls, after);
  });

  testWidgets('Equalizer-only mode hides Source', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AudioInfoView(
        data: const AudioInfoData(
          processing: [],
          systemWide: false,
          eqOnly: true,
          route: 'Speaker',
        ),
        infoSource: () async => null,
      ),
    ));
    await tester.pump();
    expect(find.text('Source'), findsNothing);
    expect(find.text('Processing'), findsOneWidget);
  });

  testWidgets('paused playback shows the limiter as On', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AudioInfoView(
        data: const AudioInfoData(
          processing: [InfoStage('limiter', 'Limiter', 'On')],
          systemWide: false,
          eqOnly: false,
          route: 'Speaker',
          playing: false,
        ),
        infoSource: () async => {'limiterReductionDb': 5.0},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('On'), findsOneWidget);
    expect(find.textContaining('reducing'), findsNothing);
  });

  testWidgets('polling pauses in the background and resumes', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: AudioInfoView(
        data: data,
        infoSource: () async {
          calls++;
          return null;
        },
      ),
    ));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final at = calls;
    await tester.pump(const Duration(seconds: 1));
    expect(calls, at);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, greaterThan(at));
  });
}

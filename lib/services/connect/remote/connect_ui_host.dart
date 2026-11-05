/// Reaching the screen from code that has no `BuildContext`.
///
/// The play entry points live in controllers and services; a remote-mode tap
/// still needs to ask "play it here instead?" or say "2 songs stayed on this
/// phone". The app's `MaterialApp` is given these keys, and [ConnectUiHost]
/// uses them.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/pages/hype_connect_page.dart';
import 'package:eq_app/themes/ember.dart';

import 'connect_play_router.dart';

class ConnectUiHost implements ConnectPlayUi {
  ConnectUiHost._();

  static final ConnectUiHost instance = ConnectUiHost._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'hypeNavigator');
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>(debugLabel: 'hypeMessenger');

  /// Opens the Hype Connect page — what tapping the background notification
  /// asks for.
  ///
  /// The notification can be tapped while the app is still starting (the
  /// navigator does not exist yet) or from a process that was running with no
  /// screen at all, so this waits a few seconds for the navigator rather than
  /// dropping the request.
  Future<void> openConnectPage() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      final navigator = navigatorKey.currentState;
      if (navigator != null) {
        // Already open (from Settings, say): the tap has nothing to add.
        if (HypeConnectPage.openCount > 0) return;
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const HypeConnectPage()),
          ),
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  void say(String message) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Ember.surfaceHigh,
        ),
      );
  }

  @override
  Future<bool> confirmPlayHere(String title, String deviceName) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    final yes = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: Ember.surface,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ember.gutter, 0, Ember.gutter, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "'$title' is only on this phone",
                style: AppFonts.displayStyle(
                  fontSize: 20,
                  color: Ember.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$deviceName is playing now and cannot reach it. Play it here '
                'instead? This phone becomes the player.',
                style: TextStyle(color: Ember.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Ember.accent,
                  foregroundColor: Ember.ground,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Play on this phone'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  foregroundColor: Ember.textSecondary,
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    return yes ?? false;
  }
}

/// "Where should music play?" — asked right after approving a desktop's link.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/connect/remote/connect_link_direction.dart';
import 'package:eq_app/services/connect/remote/connect_ui_host.dart';
import 'package:eq_app/themes/ember.dart';

/// Asks which way to link [preview] (a desktop) and carries the answer out.
/// Does nothing for a non-desktop or when Connect has not started.
Future<void> showLinkDirectionSheet(
  BuildContext context,
  LinkPreview preview,
) async {
  if (preview.kind != DeviceKind.desktop) return;
  if (HypeConnect.instance.linkDirection == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    showDragHandle: true,
    backgroundColor: Ember.surface,
    builder: (_) => _DirectionSheet(name: preview.name),
  );
}

class _DirectionSheet extends StatefulWidget {
  const _DirectionSheet({required this.name});

  final String name;

  @override
  State<_DirectionSheet> createState() => _DirectionSheetState();
}

class _DirectionSheetState extends State<_DirectionSheet> {
  final ConnectLinkDirection _direction = HypeConnect.instance.linkDirection!;

  LinkChoice _choice = LinkChoice.desktop;
  bool _touched = false;
  bool _busy = false;
  String? _error;
  bool _desktopPlaying = false;
  bool _phonePlaying = false;

  @override
  void initState() {
    super.initState();
    _phonePlaying = _direction.phonePlaying();
    _choice = preselectedChoice(
      phonePlaying: _phonePlaying,
      desktopPlaying: false,
    );
    unawaited(_discover());
  }

  /// Learns whether the desktop is already playing, to preselect and badge it.
  Future<void> _discover() async {
    final desktop = await _direction.waitForDesktop(widget.name);
    if (!mounted || desktop == null) return;
    final playing = _direction.session.isPlaying(desktop.id);
    setState(() {
      _desktopPlaying = playing;
      if (!_touched) _choice = _direction.preselect(desktop);
    });
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final desktop = await _direction.waitForDesktop(widget.name);
    if (!mounted) return;
    if (desktop == null) {
      setState(() {
        _busy = false;
        _error =
            '${widget.name} has not come online yet. Make sure Hype '
            'Muzik is open on it, then try again.';
      });
      return;
    }
    final result = await _direction.apply(_choice, desktop);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.message ?? 'Could not set that up. Try again.';
      });
      return;
    }
    Navigator.of(context).pop();
    ConnectUiHost.instance.say(
      '${_choice == LinkChoice.desktop ? 'Music plays on ${widget.name}' : 'Music plays on this phone'}'
      '${result.dropped > 0 ? '. ${result.dropped} song${result.dropped == 1 ? '' : 's'} stayed behind' : ''}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ember.gutter, 0, Ember.gutter, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Where should music play?',
              style: AppFonts.displayStyle(
                fontSize: 24,
                color: Ember.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${widget.name} is linked. Pick the speaker; the other device '
              'becomes the remote. You can change this any time from the '
              'player.',
              style: TextStyle(color: Ember.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 18),
            _ChoiceCard(
              icon: Icons.desktop_mac_rounded,
              title: 'On ${widget.name}',
              subtitle: 'This phone is the remote',
              selected: _choice == LinkChoice.desktop,
              playingNow: _desktopPlaying,
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _touched = true;
                      _choice = LinkChoice.desktop;
                    }),
            ),
            const SizedBox(height: 10),
            _ChoiceCard(
              icon: Icons.smartphone_rounded,
              title: 'On this phone',
              subtitle: '${widget.name} is the remote',
              selected: _choice == LinkChoice.phone,
              playingNow: _phonePlaying,
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _touched = true;
                      _choice = LinkChoice.phone;
                    }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFF8A80), height: 1.4),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: Ember.accent,
                foregroundColor: Ember.ground,
                disabledBackgroundColor: Ember.accentWash,
                minimumSize: const Size.fromHeight(50),
              ),
              child: _busy
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Connecting to ${widget.name}…',
                          style: TextStyle(color: Ember.textPrimary),
                        ),
                      ],
                    )
                  : Text(_error == null ? 'Continue' : 'Try again'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: Ember.textSecondary,
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('Decide later'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.playingNow,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool playingNow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Ember.accentWash : Ember.surfaceHigh,
      borderRadius: BorderRadius.circular(Ember.radiusTile),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ember.radiusTile),
            border: Border.all(
              color: selected ? Ember.accent : Ember.outline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 30,
                color: selected ? Ember.accent : Ember.textSecondary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Ember.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Ember.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    if (playingNow) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFF3DDC84),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Playing now',
                            style: TextStyle(
                              color: Color(0xFF3DDC84),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected ? Ember.accent : Ember.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '/pages/settings.dart';
import '../../navigation/shell/player_exit.dart';
import '../remote/connect_device_picker.dart';

class Header extends StatelessWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => leavePlayer(context),
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const Expanded(
            child: Text(
              'NOW PLAYING',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const ConnectPickerButton(size: 20),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const Settings()),
            ),
            icon: Icon(
              Icons.settings_rounded,
              color: Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

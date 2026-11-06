import 'package:flutter/widgets.dart';

import '../navigation/shell/motion_shell.dart';

/// The app's home route: the shell that holds the player and the library.
class IndexPage extends StatelessWidget {
  const IndexPage({super.key});

  @override
  Widget build(BuildContext context) => const MotionShell();
}

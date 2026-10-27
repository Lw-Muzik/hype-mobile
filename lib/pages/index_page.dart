import 'package:eq_app/exports/exports.dart';
import 'package:eq_app/pages/home/home_shell.dart';
import 'package:flutter_zoom_drawer/flutter_zoom_drawer.dart';

import '../controllers/drawer_controller.dart';
import '../services/update/update_service.dart';
import 'menu_screen.dart';

class IndexPage extends StatefulWidget {
  const IndexPage({super.key});

  @override
  State<IndexPage> createState() => _IndexPageState();
}

class _IndexPageState extends State<IndexPage> {
  final ZoomDrawerController _drawerController = ZoomDrawerController();

  @override
  void initState() {
    super.initState();
    // The main shell is up: update notices may now be shown.
    UpdateService.instance.markShellReady();
    // Provide the controller to the provider immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<DrawerProvider>().setController(_drawerController);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ZoomDrawer(
      controller: _drawerController,
      menuScreen: MenuScreen(),
      menuBackgroundColor: Colors.black,
      mainScreen: HomeShell(),
      borderRadius: 24.0,
      showShadow: true,
      angle: -12.0,
      // drawerShadowsBackgroundColor: Colors.grey[300],
      slideWidth: context.width * 0.85,
      // shadowLayer1Color: Colors.transparent,
      shadowLayer2Color: Colors.black.withAlpha(100),
    );
  }
}

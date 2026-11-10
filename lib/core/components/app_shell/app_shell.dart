import 'package:flutter/material.dart';

import '../../../features/cameras/components/cameras_screen/cameras_screen.dart';
import '../../../features/lights/components/lights_screen/lights_screen.dart';
import '../../../features/settings/components/settings_screen/settings_screen.dart';
import '../home_screen/home_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  void _navigate(int tab) => setState(() {
    _tab = tab;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: switch (_tab) {
        0 => HomeScreen(onNavigate: _navigate),
        1 => const LightsScreen(),
        2 => const CamerasScreen(),
        _ => const SettingsScreen(),
      },
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _navigate,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.lightbulb_outline),
          selectedIcon: Icon(Icons.lightbulb),
          label: 'Lights',
        ),
        NavigationDestination(
          icon: Icon(Icons.videocam_outlined),
          selectedIcon: Icon(Icons.videocam),
          label: 'Cameras',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
  );
}

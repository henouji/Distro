import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cameras/components/cameras_screen/cameras_screen.dart';
import '../../../features/lights/components/lights_screen/lights_screen.dart';
import '../../../features/settings/components/settings_screen/settings_screen.dart';
import '../../../features/tv_sync/components/tv_sync_screen/tv_sync_screen.dart';
import '../../../features/tv_sync/remote/tv_remote_host.dart';
import '../../../features/tv_sync/tv_platform.dart';
import '../../../features/tv_sync/tv_sync_controller.dart';
import '../home_screen/home_screen.dart';
import '../glass.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _tab = 0;
  void _navigate(int tab) => setState(() {
    _tab = tab;
  });

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(deviceIsTvProvider).value ?? false;
    // On the TV the tablet-control server must outlive tab switches, and
    // Back must not close the app (that would stop the server and sync).
    final remoteEnabled =
        isTv && ref.watch(tvRemoteHostProvider.select((s) => s.enabled));
    final syncing =
        isTv &&
        ref.watch(tvSyncProvider.select((s) => s.status)) !=
            TvSyncStatus.idle;
    return PopScope(
      canPop: !(remoteEnabled || syncing),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) ref.read(tvPlatformProvider).moveToBack();
      },
      child: _layout(context),
    );
  }

  Widget _layout(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final docked = constraints.maxWidth >= 760;
      final page = switch (_tab) {
        0 => HomeScreen(onNavigate: _navigate),
        1 => const LightsScreen(),
        2 => const CamerasScreen(),
        3 => const TvScreen(),
        _ => const SettingsScreen(),
      };
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (docked)
                GlassPanel(
                  margin: const EdgeInsets.fromLTRB(16, 16, 0, 16),
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 24,
                        child: Icon(Icons.hub_outlined),
                      ),
                      const SizedBox(height: 32),
                      Expanded(
                        child: NavigationRail(
                          selectedIndex: _tab,
                          onDestinationSelected: _navigate,
                          groupAlignment: -1,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.home_outlined),
                              selectedIcon: Icon(Icons.home),
                              label: Text('Home'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.lightbulb_outline),
                              selectedIcon: Icon(Icons.lightbulb),
                              label: Text('Lights'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.videocam_outlined),
                              selectedIcon: Icon(Icons.videocam),
                              label: Text('Cameras'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.tv_outlined),
                              selectedIcon: Icon(Icons.tv),
                              label: Text('TV'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.settings_outlined),
                              selectedIcon: Icon(Icons.settings),
                              label: Text('Settings'),
                            ),
                          ],
                        ),
                      ),
                      const Tooltip(
                        message: 'Local network only',
                        child: Icon(Icons.lan_outlined, size: 20),
                      ),
                    ],
                  ),
                ),
              Expanded(child: page),
            ],
          ),
        ),
        bottomNavigationBar: docked
            ? null
            : NavigationBar(
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
                    icon: Icon(Icons.tv_outlined),
                    selectedIcon: Icon(Icons.tv),
                    label: 'TV',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
      );
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_controller.dart';
import '../features/tv_sync/tv_platform.dart';
import 'components/app_shell/app_shell.dart';
import 'components/glass.dart';
import 'navigation.dart';

class HomeHubApp extends ConsumerWidget {
  const HomeHubApp({super.key});

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF287F80),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      color: brightness == Brightness.dark
          ? const Color(0xB3233445)
          : const Color(0xBFFFFFFF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 76,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 8,
      showValueIndicator: ShowValueIndicator.onDrag,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      height: 80,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      labelType: NavigationRailLabelType.all,
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'HomeHub',
    debugShowCheckedModeBanner: false,
    navigatorObservers: [cameraRouteObserver],
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ref.watch(settingsProvider).themeMode,
    // On a TV remote, Up/Down must move focus instead of adjusting sliders.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        navigationMode: ref.watch(deviceIsTvProvider).value == true
            ? NavigationMode.directional
            : NavigationMode.traditional,
      ),
      child: CommandBackdrop(child: child!),
    ),
    home: const AppShell(),
  );
}

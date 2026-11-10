import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_controller.dart';
import 'components/app_shell/app_shell.dart';
import 'navigation.dart';

class HomeHubApp extends ConsumerWidget {
  const HomeHubApp({super.key});

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF167D6F),
      brightness: brightness,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    appBarTheme: const AppBarTheme(centerTitle: false),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'HomeHub',
    debugShowCheckedModeBanner: false,
    navigatorObservers: [cameraRouteObserver],
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ref.watch(settingsProvider).themeMode,
    home: const AppShell(),
  );
}

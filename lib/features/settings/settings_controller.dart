import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage.dart';

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.livePreviews = true,
  });
  final ThemeMode themeMode;
  final bool livePreviews;
}

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final preferences = ref.watch(preferencesProvider);
    final theme = preferences.getString('theme');
    return AppSettings(
      themeMode:
          ThemeMode.values.where((mode) => mode.name == theme).firstOrNull ??
          ThemeMode.system,
      livePreviews: preferences.getBool('livePreviews') ?? true,
    );
  }

  Future<void> setTheme(ThemeMode mode) async {
    await ref.read(preferencesProvider).setString('theme', mode.name);
    state = AppSettings(themeMode: mode, livePreviews: state.livePreviews);
  }

  Future<void> setPreviews(bool enabled) async {
    await ref.read(preferencesProvider).setBool('livePreviews', enabled);
    state = AppSettings(themeMode: state.themeMode, livePreviews: enabled);
  }
}

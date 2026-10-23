import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app_state.dart';
import 'app/screens/backup_screens.dart';
import 'app/screens/home_screen.dart';
import 'app/screens/lock_screens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: const ZeltApp(),
    ),
  );
}

class ZeltApp extends StatelessWidget {
  const ZeltApp({super.key});

  static const seed = Color(0xFF2E6B5E);

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    return MaterialApp(
      title: 'zelt',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: mode,
      home: const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final phase = context.select<AppState, Phase>((s) => s.phase);
    final superseded = context.select<AppState, bool>((s) => s.messenger?.superseded ?? false);
    final offerBackup = context.select<AppState, bool>((s) => s.offerBackup);
    return switch (phase) {
      Phase.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      Phase.setup => const SetupScreen(),
      Phase.locked => const UnlockScreen(),
      Phase.unlocked when superseded => const SupersededScreen(),
      Phase.unlocked when offerBackup => const BackupIntroScreen(),
      Phase.unlocked => const HomeScreen(),
    };
  }
}

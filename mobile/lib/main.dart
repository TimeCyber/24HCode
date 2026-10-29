import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'background_watch_service.dart';
import 'crash_log_service.dart';
import 'notification_service.dart';
import 'screens/home_shell.dart';
import 'screens/setup_screen.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    CrashLogService.instance.installHooks();
    await CrashLogService.instance.init();
    await NotificationService.instance.init();
    await BackgroundWatchService.init();
    runApp(const CodeAssistApp());
  }, (error, stack) {
    unawaited(CrashLogService.instance.logError('Zone', error, stack));
  });
}

class CodeAssistApp extends StatelessWidget {
  const CodeAssistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadConfig(),
      child: MaterialApp(
        title: 'CodeAssist',
        debugShowCheckedModeBanner: false,
        builder: (context, child) => WithForegroundTask(
          child: child ?? const SizedBox.shrink(),
        ),
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0F766E),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        home: const RootGate(),
      ),
    );
  }
}

class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(BackgroundWatchService.setAppForeground(true));
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onTaskData(Object data) {
    if (data is Map && data['action'] == 'stop_watch') {
      unawaited(BackgroundWatchService.ensureWatching(hasInFlight: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    unawaited(BackgroundWatchService.setAppForeground(fg));
    unawaited(CrashLogService.instance.log('lifecycle', state.name));
    if (fg && mounted) {
      final app = context.read<AppState>();
      if (app.configured) {
        unawaited(app.refreshAll());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.configured) {
      return const SetupScreen();
    }
    return const HomeShell();
  }
}

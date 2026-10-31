import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // 保持系统状态栏/导航栏可见，避免沉浸式吃掉返回与 Home 手势
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: true,
      ),
    );
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
  DateTime? _lastBackAt;

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

  void _onRootBack() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }
    final now = DateTime.now();
    final last = _lastBackAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次返回退出应用'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onRootBack();
      },
      child: !state.configured ? const SetupScreen() : const HomeShell(),
    );
  }
}

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:android_intent_plus/android_intent.dart';

/// ================= CONFIG =================

const String apiUrl =
    'http://44.200.70.230:8000/Athena/api/v1/login/administrador';

const String apiPayload =
    '{"username":"roberto@ventrix.com.br","password":"Amor","documento":"662.963.746-15"}';

const int alarmId = 777;
const String prefsNextRun = 'next_run';

final Random random = Random();

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

/// ================= INIT =================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _initNotifications();

  if (Platform.isAndroid) {
    await AndroidAlarmManager.initialize();

    await _scheduleExactAlarm();
  }

  runApp(const MyApp());
}

/// ================= NOTIFICATIONS =================

Future<void> _initNotifications({bool requestPermission = true}) async {
  const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );

  await notifications.initialize(settings);
  if (requestPermission && Platform.isAndroid) {
    final androidPlugin = notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
  }
}

/// ================= API =================

Future<void> callApi() async {
  final res = await http.post(
    Uri.parse(apiUrl),
    headers: {'Content-Type': 'application/json'},
    body: apiPayload,
  );

  await notifications.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'API Executada',
    'Status: ${res.statusCode}',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'api',
        'API',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

/// ================= ALARM MANAGER =================

DateTime _nextRunAt0020() {
  final now = DateTime.now();
  DateTime run = DateTime(now.year, now.month, now.day, 0, 20);
  if (!run.isAfter(now)) {
    run = run.add(const Duration(days: 1));
  }
  return run;
}

Future<bool> _scheduleExactAlarm() async {
  final when = _nextRunAt0020();

  final scheduled = await AndroidAlarmManager.oneShotAt(
    when,
    alarmId,
    alarmCallback,
    exact: true,
    wakeup: true,
    allowWhileIdle: true,
    rescheduleOnReboot: true,
  );

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(prefsNextRun, when.toIso8601String());
  await prefs.setBool('last_schedule_ok', scheduled);

  return scheduled;
}

@pragma('vm:entry-point')
Future<void> alarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications(requestPermission: false);
  await callApi();
  await _scheduleExactAlarm();
}

/// ================= UI =================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String status = 'Agendamento ativo';
  String nextRunText = 'Carregando...';
  String exactAlarmText = 'Alarme exato: verifique nas configuracoes';

  @override
  void initState() {
    super.initState();
    _loadNextRun();
  }

  Future<void> _loadNextRun() async {
    final prefs = await SharedPreferences.getInstance();
    final nextRunIso = prefs.getString(prefsNextRun);
    final lastScheduleOk = prefs.getBool('last_schedule_ok');
    if (!mounted) return;
    setState(() {
      final nextRun = nextRunIso == null
          ? 'Sem agendamento'
          : DateTime.parse(nextRunIso).toLocal().toString();
      final scheduleInfo = lastScheduleOk == null
          ? ''
          : (lastScheduleOk ? '' : ' (falha ao agendar)');
      nextRunText = '$nextRun$scheduleInfo';
    });
  }

 void _markExactAlarmUnknown() {
  
    setState(() {
        exactAlarmText = 'Alarme exato: verifique nas configuracoes';
    });
  }

  Future<void> _disableBatteryOptimization() async {
    const AndroidIntent intent = AndroidIntent(
      action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
    );
    await intent.launch();
  }

  Future<void> _testNow() async {
    setState(() {
      status = 'Executando teste...';
    });
    await callApi();
    if (!mounted) return;
    setState(() {
      status = 'Teste concluido';
    });
  }

  Future<void> _reschedule() async {
    setState(() {
      status = 'Reagendando...';
    });
    final ok = await _scheduleExactAlarm();
    await _loadNextRun();
    _markExactAlarmUnknown();
    if (!mounted) return;
    setState(() {
      status = ok ? 'Agendamento atualizado' : 'Falha ao agendar';
    });
  }

  Future<void> _openExactAlarmSettings() async {
    const AndroidIntent intent = AndroidIntent(
      action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
    );
    await intent.launch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agendamento Diario')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(status),
            const SizedBox(height: 8),
            Text('Proximo: $nextRunText'),
            const SizedBox(height: 8),
            Text(exactAlarmText),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _openExactAlarmSettings,
              child: const Text('Permissao de Alarme Exato'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _disableBatteryOptimization,
              child: const Text('Desativar Otimizacao de Bateria'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _reschedule,
              child: const Text('Reagendar Agora'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testNow,
              child: const Text('Testar Notificacao'),
            ),
          ],
        ),
      ),
    );
  }
}

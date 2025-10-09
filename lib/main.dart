import 'dart:io';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

const int kAlarmId = 1005;
const String kApiUrl = 'http://44.200.70.230:8000/Athena/api/v1/login/administrador';
const String kPayload =
    '{"username": "roberto@ventrix.com.br","password": "Amor","documento": "662.963.746-15"}';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const AndroidInitializationSettings android =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings ios = DarwinInitializationSettings();
  const InitializationSettings initSettings =
      InitializationSettings(android: android, iOS: ios);
  await flutterLocalNotificationsPlugin.initialize(initSettings);
}

Future<void> _notify(String title, String body) async {
  const AndroidNotificationDetails android = AndroidNotificationDetails(
    'api_channel',
    'API',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );
  const DarwinNotificationDetails ios = DarwinNotificationDetails();
  const NotificationDetails details =
      NotificationDetails(android: android, iOS: ios);

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    details,
  );
}

DateTime _next00h05() {
  final DateTime now = DateTime.now();
  DateTime target = DateTime(now.year, now.month, now.day, 0, 5);
  if (!target.isAfter(now)) {
    target = target.add(const Duration(days: 1));
  }
  return target;
}

Future<DateTime?> scheduleExactAt00h05() async {
  final DateTime when = _next00h05();
  final bool scheduled = await AndroidAlarmManager.oneShotAt(
            when,
            kAlarmId,
            alarmCallback,
            exact: true,
            wakeup: true,
            allowWhileIdle: true,
            rescheduleOnReboot: true,
          ) ??
          false;

  return scheduled ? when : null;
}

Future<void> openExactAlarmSettings() async {
  if (!Platform.isAndroid) return;
  const AndroidIntent intent = AndroidIntent(
    action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
  );

  await intent.launch();
}

@pragma('vm:entry-point')
Future<void> alarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  const AndroidInitializationSettings android =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings ios = DarwinInitializationSettings();
  const InitializationSettings initSettings =
      InitializationSettings(android: android, iOS: ios);

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  try {
    await _notify('Comando enviado', 'Chamando a API configurada.');

    final http.Response resp = await http.post(
      Uri.parse(kApiUrl),
      headers: {'Content-Type': 'application/json'},
      body:{
            'username': "roberto@ventrix.com.br",
            'password': "Amor",
            'documento': "662.963.746-15"
          },
    );

    final String bodyPreview =
        resp.body.length <= 120 ? resp.body : '${resp.body.substring(0, 120)}...';

    await _notify('Resposta recebida', 'Status: ${resp.statusCode} - $bodyPreview');
  } catch (e) {
    await _notify('Falha ao enviar', e.toString());
  } finally {
    await scheduleExactAt00h05();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();

  if (Platform.isAndroid) {
    await AndroidAlarmManager.initialize();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Server App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const SchedulerPage(),
    );
  }
}

class SchedulerPage extends StatefulWidget {
  const SchedulerPage({super.key});

  @override
  State<SchedulerPage> createState() => _SchedulerPageState();
}

class _SchedulerPageState extends State<SchedulerPage> {
  DateTime? _nextTrigger;
  String _status = 'Preparando agendamento...';
  bool _isScheduling = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _schedule();
    } else {
      _status = 'Agendamento disponivel apenas no Android.';
    }
  }

  Future<void> _schedule() async {
    setState(() {
      _isScheduling = true;
      _nextTrigger = _next00h05();
      _status = 'Agendando para ${_formatDateTime(_nextTrigger!)}';
    });

    final DateTime? scheduledAt = await scheduleExactAt00h05();

    if (!mounted) return;

    setState(() {
      _isScheduling = false;
      if (scheduledAt != null) {
        _nextTrigger = scheduledAt;
        _status = 'Proximo disparo agendado para ${_formatDateTime(scheduledAt)}';
      } else {
        _status = 'Nao foi possivel agendar. Verifique as permissoes.';
      }
    });
  }

  Future<void> _openSettings() async {
    await openExactAlarmSettings();
  }

  Future<void> _runNow() async {
    setState(() {
      _status = 'Executando agora...';
    });

    await alarmCallback();

    if (!mounted) return;
    setState(() {
      _status = 'Comando executado manualmente. Novo agendamento configurado.';
      _nextTrigger = _next00h05();
    });
  }

  String _formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final String day = twoDigits(dateTime.day);
    final String month = twoDigits(dateTime.month);
    final String hour = twoDigits(dateTime.hour);
    final String minute = twoDigits(dateTime.minute);
    return '$day/$month/${dateTime.year} as $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agendamento diario'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _status,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (_nextTrigger != null)
              Text(
                'Proxima execucao: ${_formatDateTime(_nextTrigger!)}',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isScheduling ? null : _schedule,
              child: Text(_isScheduling ? 'Agendando...' : 'Reagendar 00:05'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _openSettings,
              child: const Text('Abrir permissoes de alarmes exatos'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _runNow,
              child: const Text('Executar agora (teste)'),
            ),
          ],
        ),
      ),
    );
  }
}

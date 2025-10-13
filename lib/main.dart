import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const int kAlarmId = 1005;
const String kApiUrl =
    'http://44.200.70.230:8000/Athena/api/v1/login/administrador';
const String kPayload =
    '{"username": "roberto@ventrix.com.br","password": "Amor","documento": "662.963.746-15"}';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const String kNextTriggerPrefsKey = 'next_trigger_iso';
final Random _random = Random();

class CommandResult {
  const CommandResult.success({required this.statusCode, required this.preview})
    : success = true,
      errorMessage = null;

  const CommandResult.failure(this.errorMessage)
    : success = false,
      statusCode = null,
      preview = null;

  final bool success;
  final int? statusCode;
  final String? preview;
  final String? errorMessage;
}

Future<void> _initNotifications() async {
  const AndroidInitializationSettings android = AndroidInitializationSettings(
    '@mipmap/ic_launcher',
  );
  const DarwinInitializationSettings ios = DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(
    android: android,
    iOS: ios,
  );
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
      flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
  await androidPlugin?.requestNotificationsPermission();
}

String _bodyPreview(String body) =>
    body.length <= 120 ? body : '${body.substring(0, 120)}...';

Future<CommandResult> _performApiCall() async {
  try {
    final http.Response resp = await http.post(
      Uri.parse(kApiUrl),
      headers: {'Content-Type': 'application/json'},
      body: kPayload,
    );

    return CommandResult.success(
      statusCode: resp.statusCode,
      preview: _bodyPreview(resp.body),
    );
  } catch (e) {
    return CommandResult.failure(e.toString());
  }
}

Future<void> _notify(String title, String body) async {
  const AndroidNotificationDetails android = AndroidNotificationDetails(
    'api_channel',
    'API',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );
  const DarwinNotificationDetails ios = DarwinNotificationDetails();
  const NotificationDetails details = NotificationDetails(
    android: android,
    iOS: ios,
  );

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    details,
  );
}

Future<void> _tryNotify(String title, String body) async {
  try {
    await _notify(title, body);
  } catch (_) {}
}

const Duration kMaxJitter = Duration(minutes: 10);

DateTime _next00h05() {
  final DateTime now = DateTime.now();
  DateTime target = DateTime(now.year, now.month, now.day, 00, 30);
  if (!target.isAfter(now)) {
    target = target.add(const Duration(days: 1));
  }
  if (kMaxJitter.inMinutes > 0) {
    final int jitterMinutes = _random.nextInt(kMaxJitter.inMinutes + 1);
    target = target.add(Duration(minutes: jitterMinutes));
  }
  return target;
}

Future<SharedPreferences?> _safePrefs() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (_) {
    return null;
  }
}

Future<void> _persistNextTrigger(DateTime when) async {
  final SharedPreferences? prefs = await _safePrefs();
  await prefs?.setString(kNextTriggerPrefsKey, when.toIso8601String());
}

Future<void> _clearStoredNextTrigger() async {
  final SharedPreferences? prefs = await _safePrefs();
  await prefs?.remove(kNextTriggerPrefsKey);
}

Future<DateTime?> _loadStoredNextTrigger() async {
  final SharedPreferences? prefs = await _safePrefs();
  final String? raw = prefs?.getString(kNextTriggerPrefsKey);
  if (raw == null || raw.isEmpty) return null;
  try {
    return DateTime.parse(raw);
  } catch (_) {
    return null;
  }
}

Future<DateTime?> ensureDailyAlarmScheduled() async {
  if (!Platform.isAndroid) return null;
  DateTime? stored;
  try {
    stored = await _loadStoredNextTrigger();
  } catch (_) {
    stored = null;
  }
  final DateTime now = DateTime.now();
  if (stored != null && stored.isAfter(now)) {
    return stored;
  }
  try {
    return await scheduleExactAt00h05();
  } catch (_) {
    return null;
  }
}

Future<DateTime?> scheduleExactAt00h05() async {
  if (!Platform.isAndroid) return null;
  final DateTime when = _next00h05();
  bool scheduled = false;
  try {
    scheduled =
        await AndroidAlarmManager.oneShotAt(
          when,
          kAlarmId,
          alarmCallback,
          exact: true,
          wakeup: true,
          allowWhileIdle: true,
          rescheduleOnReboot: true,
        ) ??
        false;
  } catch (_) {
    scheduled = false;
  }

  if (scheduled) {
    await _persistNextTrigger(when);
    return when;
  }

  await _clearStoredNextTrigger();
  return null;
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

  const AndroidInitializationSettings android = AndroidInitializationSettings(
    '@mipmap/ic_launcher',
  );
  const DarwinInitializationSettings ios = DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(
    android: android,
    iOS: ios,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  try {
    await _tryNotify('Comando enviado', 'Chamando a API configurada.');

    final CommandResult result = await _performApiCall();

    if (result.success) {
      await _tryNotify(
        'Resposta recebida',
        'Status: ${result.statusCode} - ${result.preview}',
      );
    } else {
      await _tryNotify(
        'Falha ao enviar',
        result.errorMessage ?? 'Erro desconhecido',
      );
    }
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
    _initializeSchedule();
  }

  Future<void> _initializeSchedule() async {
    if (!Platform.isAndroid) {
      setState(() {
        _status = 'Agendamento disponivel apenas no Android.';
      });
      return;
    }

    setState(() {
      _status = 'Verificando agendamento diario...';
    });

    DateTime? next;
    try {
      next = await ensureDailyAlarmScheduled();
    } catch (_) {
      next = null;
    }

    if (!mounted) return;

    if (next != null) {
      setState(() {
        _nextTrigger = next;
        _status = 'Proximo disparo agendado para ${_formatDateTime(next!)}';
      });
    } else {
      setState(() {
        _status =
            'Nao foi possivel agendar automaticamente. Verifique as permissoes.';
      });
      final DateTime? stored = await _loadStoredNextTrigger();
      if (!mounted) return;
      if (stored != null) {
        setState(() {
          _nextTrigger = stored;
        });
      }
    }
  }

  Future<void> _schedule() async {
    setState(() {
      _isScheduling = true;
      _status = 'Criando agendamento diario...';
    });

    DateTime? scheduledAt;
    try {
      scheduledAt = await scheduleExactAt00h05();
    } catch (_) {
      scheduledAt = null;
    }

    if (!mounted) return;

    setState(() {
      _isScheduling = false;
      if (scheduledAt != null) {
        _nextTrigger = scheduledAt;
        _status =
            'Proximo disparo agendado para ${_formatDateTime(scheduledAt)}';
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

    await _tryNotify('Comando enviado', 'Execucao manual iniciada.');

    final CommandResult result = await _performApiCall();

    if (result.success) {
      await _tryNotify(
        'Resposta recebida',
        'Status: ${result.statusCode} - ${result.preview}',
      );
    } else {
      await _tryNotify(
        'Falha ao enviar',
        result.errorMessage ?? 'Erro desconhecido',
      );
    }

    DateTime? rescheduled;
    if (Platform.isAndroid) {
      try {
        rescheduled = await scheduleExactAt00h05();
      } catch (_) {
        rescheduled = null;
      }
    }

    if (!mounted) return;

    setState(() {
      _status = result.success
          ? 'Comando executado manualmente. Status: ${result.statusCode}.'
          : 'Falha ao executar manualmente: ${result.errorMessage ?? 'erro desconhecido'}';
      if (rescheduled != null) {
        _nextTrigger = rescheduled;
      }
    });

    if (!result.success) {
      final String message =
          result.errorMessage ?? 'Falha desconhecida ao enviar o comando.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }

    if (Platform.isAndroid && rescheduled == null) {
      final DateTime? stored = await _loadStoredNextTrigger();
      if (!mounted) return;
      if (stored != null) {
        setState(() {
          _nextTrigger = stored;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nao foi possivel reagendar automaticamente. Verifique as permissoes.',
          ),
        ),
      );
    }
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
      appBar: AppBar(title: const Text('Agendamento diario')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            if (_nextTrigger != null)
              Text(
                'Proxima execucao: ${_formatDateTime(_nextTrigger!)}',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isScheduling ? null : _schedule,
              child: Text(_isScheduling ? 'Agendando...' : 'Reagendar 00:30'),
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

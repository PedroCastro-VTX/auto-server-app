import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ================= CONFIG =================

const String apiUrl =
    'http://44.200.70.230:8000/Athena/api/v1/login/administrador';

const String apiPayload =
    '{"username":"roberto@ventrix.com.br","password":"Amor","documento":"662.963.746-15"}';

const int alarmId = 777;
const String prefsNextRun = 'next_run';
const String prefsScheduleError = 'last_schedule_error';
const String prefsLastApiStatus = 'last_api_status';
const String prefsLastNotificationError = 'last_notification_error';
const String notificationChannelId = 'api';
const String notificationChannelName = 'API';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

/// ================= INIT =================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _initNotifications();

  if (Platform.isAndroid) {
    await AndroidAlarmManager.initialize();
    await _ensureScheduleOnStartup();
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

  if (Platform.isAndroid) {
    final androidPlugin = notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        notificationChannelId,
        notificationChannelName,
        description: 'Notificacoes de status da API',
        importance: Importance.high,
      ),
    );

    if (requestPermission) {
      await androidPlugin?.requestNotificationsPermission();
    }
  }
}

Future<void> _showNotification(String title, String body) async {
  await notifications.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        notificationChannelId,
        notificationChannelName,
        channelDescription: 'Notificacoes de status da API',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

Future<void> _showNotificationSafe(String title, String body) async {
  try {
    await _showNotification(title, body).timeout(const Duration(seconds: 5));

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsLastNotificationError);
  } catch (e) {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toLocal().toString();
    await prefs.setString(prefsLastNotificationError, '$now - $e');
    print('Erro ao exibir notificacao: $e');
  }
}

Future<void> _saveLastApiStatus(String message) async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now().toLocal().toString();
  await prefs.setString(prefsLastApiStatus, '$now - $message');
}

class ApiCallResult {
  const ApiCallResult({
    required this.success,
    required this.title,
    required this.message,
  });

  final bool success;
  final String title;
  final String message;
}

/// ================= API =================

Future<ApiCallResult> _performApiCall() async {
  final uri = Uri.parse(apiUrl);
  final host = uri.host;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

  HttpClient? client;

  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    await socket.close();

    client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    final request = await client.postUrl(uri).timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw TimeoutException('Timeout ao abrir conexao HTTP.');
      },
    );

    request.headers.contentType = ContentType.json;
    request.write(apiPayload);

    final response = await request.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw TimeoutException('A API nao respondeu em 10 segundos.');
      },
    );

    final responseBody = await utf8.decoder.bind(response).join().timeout(
      const Duration(seconds: 5),
      onTimeout: () => '',
    );

    if (response.statusCode >= 400) {
      return ApiCallResult(
        success: false,
        title: 'Falha na requisicao',
        message:
            'Servidor respondeu com status ${response.statusCode}. Corpo: $responseBody',
      );
    }

    return ApiCallResult(
      success: true,
      title: 'API Executada',
      message: 'Status: ${response.statusCode}',
    );
  } on SocketException catch (e) {
    return ApiCallResult(
      success: false,
      title: 'Falha na requisicao',
      message: 'Servidor offline ou porta fechada: ${e.message}',
    );
  } on TimeoutException catch (e) {
    return ApiCallResult(
      success: false,
      title: 'Falha na requisicao',
      message: e.message ?? 'Tempo limite excedido.',
    );
  } catch (e) {
    return ApiCallResult(
      success: false,
      title: 'Falha na requisicao',
      message: 'Erro inesperado: $e',
    );
  } finally {
    client?.close(force: true);
  }
}

Future<bool> callApi() async {
  final result = await _performApiCall().timeout(
    const Duration(seconds: 20),
    onTimeout: () => const ApiCallResult(
      success: false,
      title: 'Falha na requisicao',
      message: 'Timeout geral da API apos 20 segundos.',
    ),
  );

  await _saveLastApiStatus(result.message);
  await _showNotificationSafe(result.title, result.message);
  return result.success;
}

/// ================= ALARM MANAGER =================

DateTime _nextRunAtDailyTime() {
  final now = DateTime.now();
  DateTime run = DateTime(now.year, now.month, now.day, 0, 20);

  if (!run.isAfter(now)) {
    run = run.add(const Duration(days: 1));
  }

  return run;
}

Future<void> _ensureScheduleOnStartup() async {
  final prefs = await SharedPreferences.getInstance();
  final nextRunIso = prefs.getString(prefsNextRun);

  if (nextRunIso == null) {
    await _scheduleExactAlarm();
    return;
  }

  final nextRun = DateTime.tryParse(nextRunIso);
  if (nextRun == null || !nextRun.isAfter(DateTime.now())) {
    await _scheduleExactAlarm();
  }
}

Future<bool> _scheduleExactAlarm() async {
  final when = _nextRunAtDailyTime();
  final prefs = await SharedPreferences.getInstance();

  try {
    final scheduled = await AndroidAlarmManager.oneShotAt(
      when,
      alarmId,
      alarmCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
    );

    if (scheduled) {
      await prefs.setString(prefsNextRun, when.toIso8601String());
      await prefs.remove(prefsScheduleError);
    } else {
      await prefs.remove(prefsNextRun);
      await prefs.setString(
        prefsScheduleError,
        'O Android recusou o reagendamento diario.',
      );
    }

    await prefs.setBool('last_schedule_ok', scheduled);
    return scheduled;
  } catch (e) {
    await prefs.remove(prefsNextRun);
    await prefs.setBool('last_schedule_ok', false);
    await prefs.setString(prefsScheduleError, e.toString());
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> alarmCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications(requestPermission: false);
  await AndroidAlarmManager.initialize();

  final rescheduled = await _scheduleExactAlarm();

  try {
    await callApi().timeout(
      const Duration(seconds: 25),
      onTimeout: () async {
        await _saveLastApiStatus('Timeout no callback do alarme apos 25 segundos.');
        await _showNotificationSafe(
          'Falha na requisicao',
          'Timeout no callback do alarme apos 25 segundos.',
        );
        return false;
      },
    );
  } catch (e) {
    await _saveLastApiStatus('Erro no callback do alarme: $e');
    await _showNotificationSafe(
      'Falha na requisicao',
      'Erro no callback do alarme: $e',
    );
  }

  if (!rescheduled) {
    await _showNotificationSafe(
      'Falha no reagendamento',
      'Abra o app e toque em Reagendar Agora.',
    );
  }
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
  String lastApiText = 'Ultima execucao: sem dados';
  String lastNotificationErrorText = 'Erro de notificacao: nenhum';

  @override
  void initState() {
    super.initState();
    _loadNextRun();
  }

  Future<void> _loadNextRun() async {
    final prefs = await SharedPreferences.getInstance();
    final nextRunIso = prefs.getString(prefsNextRun);
    final lastScheduleOk = prefs.getBool('last_schedule_ok');
    final scheduleError = prefs.getString(prefsScheduleError);
    final lastApiStatus = prefs.getString(prefsLastApiStatus);
    final lastNotificationError = prefs.getString(prefsLastNotificationError);

    if (!mounted) return;

    setState(() {
      final nextRun = nextRunIso == null
          ? 'Sem agendamento'
          : DateTime.parse(nextRunIso).toLocal().toString();

      final scheduleInfo = lastScheduleOk == null
          ? ''
          : (lastScheduleOk
              ? ''
              : ' (falha ao agendar${scheduleError == null ? '' : ': $scheduleError'})');

      nextRunText = '$nextRun$scheduleInfo';

      lastApiText = lastApiStatus == null
          ? 'Ultima execucao: sem dados'
          : 'Ultima execucao: $lastApiStatus';

      lastNotificationErrorText = lastNotificationError == null
          ? 'Erro de notificacao: nenhum'
          : 'Erro de notificacao: $lastNotificationError';
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
    if (!mounted) return;

    setState(() {
      status = 'Executando teste...';
    });

    ApiCallResult result;

    try {
      result = await _performApiCall().timeout(
        const Duration(seconds: 20),
        onTimeout: () => const ApiCallResult(
          success: false,
          title: 'Falha na requisicao',
          message: 'Timeout geral do teste apos 20 segundos.',
        ),
      );

      if (!mounted) return;
      setState(() {
        status = 'Salvando status...';
      });

      await _saveLastApiStatus(result.message).timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );

      if (!mounted) return;
      setState(() {
        status = 'Enviando notificacao...';
      });

      await _showNotificationSafe(result.title, result.message).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );

      await _loadNextRun().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    } catch (e) {
      result = ApiCallResult(
        success: false,
        title: 'Erro no teste',
        message: 'Falha inesperada no fluxo de teste: $e',
      );

      await _saveLastApiStatus(result.message);
    }

    if (!mounted) return;
    setState(() {
      status = '${result.title}: ${result.message}';
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(status),
              const SizedBox(height: 8),
              Text('Proximo: $nextRunText'),
              const SizedBox(height: 8),
              Text(exactAlarmText),
              const SizedBox(height: 8),
              Text(lastApiText),
              const SizedBox(height: 8),
              Text(lastNotificationErrorText),
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
      ),
    );
  }
}
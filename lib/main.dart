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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1652B9)),
      ),
      home: const HomePage(),
    );
  }
}

class _PanelChip {
  const _PanelChip(this.label, this.backgroundColor, this.textColor);

  final String label;
  final Color backgroundColor;
  final Color textColor;
}

class _AdminPanelItem {
  const _AdminPanelItem({
    required this.icon,
    required this.iconBackgroundColor,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.chips,
    required this.onTap,
  });

  final IconData icon;
  final Color iconBackgroundColor;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<_PanelChip> chips;
  final Future<void> Function() onTap;
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

  String _formatDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.day)}/${two(value.month)}/${value.year} ${two(value.hour)}:${two(value.minute)}';
  }

  bool get _isScheduleHealthy {
    final text = nextRunText.toLowerCase();
    return !text.contains('falha') && !text.contains('sem agendamento');
  }

  bool get _isApiHealthy {
    final text = status.toLowerCase();
    return !text.contains('falha') && !text.contains('erro');
  }

  bool get _isNotificationHealthy =>
      lastNotificationErrorText.toLowerCase().endsWith('nenhum');

  Future<void> _loadNextRun() async {
    final prefs = await SharedPreferences.getInstance();
    final nextRunIso = prefs.getString(prefsNextRun);
    final lastScheduleOk = prefs.getBool('last_schedule_ok');
    final scheduleError = prefs.getString(prefsScheduleError);
    final lastApiStatus = prefs.getString(prefsLastApiStatus);
    final lastNotificationError = prefs.getString(prefsLastNotificationError);

    if (!mounted) return;

    setState(() {
      final parsedNextRun =
          nextRunIso == null ? null : DateTime.tryParse(nextRunIso)?.toLocal();
      final nextRun = parsedNextRun == null
          ? 'Sem agendamento'
          : _formatDateTime(parsedNextRun);

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

  Future<void> _openQuickActionsSheet() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.alarm_rounded),
                title: const Text('Permissao de Alarme Exato'),
                onTap: () {
                  Navigator.pop(context);
                  _openExactAlarmSettings();
                },
              ),
              ListTile(
                leading: const Icon(Icons.battery_saver_rounded),
                title: const Text('Desativar Otimizacao de Bateria'),
                onTap: () {
                  Navigator.pop(context);
                  _disableBatteryOptimization();
                },
              ),
              ListTile(
                leading: const Icon(Icons.update_rounded),
                title: const Text('Reagendar Agora'),
                onTap: () {
                  Navigator.pop(context);
                  _reschedule();
                },
              ),
              ListTile(
                leading: const Icon(Icons.notifications_active_rounded),
                title: const Text('Testar Notificacao'),
                onTap: () {
                  Navigator.pop(context);
                  _testNow();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  List<_AdminPanelItem> _buildPanelItems() {
    final scheduleHealthy = _isScheduleHealthy;
    final apiHealthy = _isApiHealthy;
    final notificationHealthy = _isNotificationHealthy;

    return [
      _AdminPanelItem(
        icon: Icons.event_repeat_rounded,
        iconBackgroundColor: const Color(0xFFDDE8FF),
        iconColor: const Color(0xFF1C4AA8),
        title: 'Agendamento Diario',
        subtitle: nextRunText,
        chips: [
          _PanelChip(
            scheduleHealthy ? 'Ativo' : 'Atencao',
            scheduleHealthy ? const Color(0xFFE9F5DD) : const Color(0xFFFFF2DB),
            scheduleHealthy ? const Color(0xFF4E7A13) : const Color(0xFF9C6A08),
          ),
        ],
        onTap: _reschedule,
      ),
      _AdminPanelItem(
        icon: Icons.cloud_sync_rounded,
        iconBackgroundColor: const Color(0xFFD9F3EC),
        iconColor: const Color(0xFF046A56),
        title: 'Status da API',
        subtitle: status,
        chips: [
          _PanelChip(
            apiHealthy ? 'Ativo' : 'Offline',
            apiHealthy ? const Color(0xFFE9F5DD) : const Color(0xFFFFE2E0),
            apiHealthy ? const Color(0xFF4E7A13) : const Color(0xFF9E2B2B),
          ),
          const _PanelChip(
            'Teste',
            Color(0xFFECE8FF),
            Color(0xFF5A49CC),
          ),
        ],
        onTap: _testNow,
      ),
      _AdminPanelItem(
        icon: Icons.notifications_active_rounded,
        iconBackgroundColor: const Color(0xFFFFEACC),
        iconColor: const Color(0xFF9B5400),
        title: 'Notificacoes',
        subtitle: notificationHealthy
            ? 'Sem erros recentes'
            : lastNotificationErrorText.replaceFirst('Erro de notificacao: ', ''),
        chips: [
          _PanelChip(
            notificationHealthy ? 'Ativo' : 'Falha',
            notificationHealthy ? const Color(0xFFE9F5DD) : const Color(0xFFFFE2E0),
            notificationHealthy ? const Color(0xFF4E7A13) : const Color(0xFF9E2B2B),
          ),
          const _PanelChip(
            'Sistema',
            Color(0xFFECE8FF),
            Color(0xFF5A49CC),
          ),
        ],
        onTap: _openQuickActionsSheet,
      ),
      _AdminPanelItem(
        icon: Icons.settings_suggest_rounded,
        iconBackgroundColor: const Color(0xFFE7EBF3),
        iconColor: const Color(0xFF40546B),
        title: 'Permissoes',
        subtitle: exactAlarmText,
        chips: const [
          _PanelChip(
            'Configurar',
            Color(0xFFECE8FF),
            Color(0xFF5A49CC),
          ),
        ],
        onTap: _openExactAlarmSettings,
      ),
    ];
  }

  Widget _buildHeroCard() {
    final allHealthy = _isScheduleHealthy && _isApiHealthy && _isNotificationHealthy;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D2F70), Color(0xFF1652B9)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.admin_panel_settings_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Athena Disparo Diário',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Monitoramento de automacao',
            style: TextStyle(
              color: Colors.white,
              fontSize: 32 / 2,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Acompanhe API, notificacoes e agendamento diario em uma visao unica.',
            style: TextStyle(
              color: Color(0xFFD8E5FF),
              fontSize: 17 / 2,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              allHealthy ? 'Operacao estavel' : 'Atencao em diagnosticos',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            lastApiText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewStrip() {
    return Row(
      children: [
        Expanded(
          child: _buildOverviewPill(
            icon: Icons.schedule_rounded,
            label: 'Agenda',
            healthy: _isScheduleHealthy,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildOverviewPill(
            icon: Icons.lan_rounded,
            label: 'API',
            healthy: _isApiHealthy,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildOverviewPill(
            icon: Icons.notifications_rounded,
            label: 'Notif',
            healthy: _isNotificationHealthy,
          ),
        ),
      ],
    );
  }

  Widget _buildOverviewPill({
    required IconData icon,
    required String label,
    required bool healthy,
  }) {
    final backgroundColor =
        healthy ? const Color(0xFFE6F4E9) : const Color(0xFFFFEFEA);
    final foregroundColor =
        healthy ? const Color(0xFF1E6A2A) : const Color(0xFFA73E1B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: foregroundColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label ${healthy ? 'ok' : 'falha'}',
              style: TextStyle(
                color: foregroundColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle() {
    return const Text(
      'Controles e diagnostico',
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xFF4E5566),
        letterSpacing: 0.1,
      ),
    );
  }

  Widget _buildBottomActionBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        color: Colors.white,
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _reschedule,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF244B9B),
                    side: const BorderSide(color: Color(0xFFC6D6F6)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.update_rounded, size: 20),
                  label: const Text(
                    'Reagendar',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _testNow,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: const Color(0xFF1652B9),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 22),
                  label: const Text(
                    'Testar API',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemCard(_AdminPanelItem item) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE7E7EE)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: item.iconBackgroundColor,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  item.icon,
                  color: item.iconColor,
                  size: 23,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2B2B39),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF85859A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: item.chips
                          .map(
                            (chip) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: chip.backgroundColor,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                chip.label,
                                style: TextStyle(
                                  color: chip.textColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFFB8B8C7),
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildPanelItems();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFFF4F7FB),
        leading: IconButton(
          onPressed: _openQuickActionsSheet,
          icon: const Icon(Icons.menu_rounded, color: Color(0xFF2A2A37)),
        ),
        title: const Text(
          'Athena Admin',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF2A2A37),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _loadNextRun,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF2A2A37)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadNextRun,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            _buildHeroCard(),
            const SizedBox(height: 16),
            _buildOverviewStrip(),
            const SizedBox(height: 14),
            _buildSectionTitle(),
            const SizedBox(height: 10),
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildItemCard(item),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomActionBar(),
    );
  }
}

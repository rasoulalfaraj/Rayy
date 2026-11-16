import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await notificationsPlugin.initialize(initSettings);

  final androidImpl = notificationsPlugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.requestNotificationsPermission();

  runApp(const RayyApp());
}

class RayyApp extends StatelessWidget {
  const RayyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'رَيّ - تذكير شرب المياه',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0284C7),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0284C7),
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // بيانات المستخدم
  double _weight = 75.0;
  String _activity = 'moderate'; // low, moderate, high
  int _wakeHour = 7;
  int _sleepHour = 23;
  int _intervalMinutes = 90;

  // بيانات الطقس
  String _cityName = 'بغداد / ذي قار';
  double _temperature = 32.0;
  int _humidity = 35;
  String _weatherDesc = 'مشمس دافئ';
  bool _isLoadingWeather = false;

  // التتبع اليومي
  int _consumedMl = 0;
  List<String> _logs = [];
  bool _remindersActive = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = DateTime.now().toIso8601String().substring(0, 10);
    final savedDate = prefs.getString('saved_date') ?? '';

    setState(() {
      _weight = prefs.getDouble('weight') ?? 75.0;
      _activity = prefs.getString('activity') ?? 'moderate';
      _wakeHour = prefs.getInt('wake_hour') ?? 7;
      _sleepHour = prefs.getInt('sleep_hour') ?? 23;
      _intervalMinutes = prefs.getInt('interval') ?? 90;
      _temperature = prefs.getDouble('temp') ?? 32.0;
      _humidity = prefs.getInt('humidity') ?? 35;
      _cityName = prefs.getString('city') ?? 'الطقس المحلي';
      _weatherDesc = prefs.getString('weather_desc') ?? 'معتدل إلى حار';
      _remindersActive = prefs.getBool('reminders_active') ?? true;

      if (savedDate == todayKey) {
        _consumedMl = prefs.getInt('consumed_ml') ?? 0;
        _logs = prefs.getStringList('logs') ?? [];
      } else {
        _consumedMl = 0;
        _logs = [];
      }
    });

    if (_remindersActive) {
      await _scheduleReminders();
    }
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = DateTime.now().toIso8601String().substring(0, 10);
    await prefs.setString('saved_date', todayKey);
    await prefs.setDouble('weight', _weight);
    await prefs.setString('activity', _activity);
    await prefs.setInt('wake_hour', _wakeHour);
    await prefs.setInt('sleep_hour', _sleepHour);
    await prefs.setInt('interval', _intervalMinutes);
    await prefs.setDouble('temp', _temperature);
    await prefs.setInt('humidity', _humidity);
    await prefs.setString('city', _cityName);
    await prefs.setString('weather_desc', _weatherDesc);
    await prefs.setBool('reminders_active', _remindersActive);
    await prefs.setInt('consumed_ml', _consumedMl);
    await prefs.setStringList('logs', _logs);
  }

  // معادلة حساب الاحتياج الفعلي المرتبطة بالطقس والنشاط
  int get _baseNeedMl => (_weight * 33).round();

  int get _activityBonusMl {
    switch (_activity) {
      case 'high':
        return 700;
      case 'moderate':
        return 350;
      default:
        return 0;
    }
  }

  int get _weatherBonusMl {
    int bonus = 0;
    if (_temperature > 25) {
      bonus += ((_temperature - 25) * 45).round();
    }
    if (_humidity < 30 || _humidity > 75) {
      bonus += 200;
    }
    return bonus;
  }

  int get _totalTargetMl => _baseNeedMl + _activityBonusMl + _weatherBonusMl;

  // جلب الطقس الحقيقي عبر GPS من Open-Meteo (مجاني ولا يحتاج مفتاح API)
  Future<void> _fetchLiveWeather() async {
    setState(() => _isLoadingWeather = true);
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _showSnack('يرجى تفعيل صلاحية الموقع لجلب الطقس تلقائياً.');
        setState(() => _isLoadingWeather = false);
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.low),
      );

      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${pos.latitude}&longitude=${pos.longitude}&current=temperature_2m,relative_humidity_2m,weather_code',
      );
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final current = data['current'];
        final double temp = (current['temperature_2m'] as num).toDouble();
        final int hum = (current['relative_humidity_2m'] as num).toInt();

        setState(() {
          _temperature = temp;
          _humidity = hum;
          _cityName =
              'موقعك الحالي (${pos.latitude.toStringAsFixed(2)}, ${pos.longitude.toStringAsFixed(2)})';
          _weatherDesc = temp >= 38
              ? 'حار جداً (يحتاج ترطيب مكثف)'
              : temp >= 28
                  ? 'دافئ إلى حار'
                  : 'معتدل';
        });
        await _saveData();
        if (_remindersActive) await _scheduleReminders();
        _showSnack('تم تحديث الطقس وحساب احتياجك الجديد!');
      }
    } catch (e) {
      _showSnack('تعذر الاتصال بخدمة الطقس، تأكد من الإنترنت.');
    } finally {
      setState(() => _isLoadingWeather = false);
    }
  }

  // جدولة إشعارات التذكير طوال اليوم
  Future<void> _scheduleReminders() async {
    await notificationsPlugin.cancelAll();
    if (!_remindersActive) return;

    final now = tz.TZDateTime.now(tz.local);
    int id = 1;
    int cupSize = 250;

    for (int hour = _wakeHour; hour <= _sleepHour; hour++) {
      for (int min = 0; min < 60; min += _intervalMinutes) {
        if (min >= 60) break;
        var scheduled =
            tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, min);
        if (scheduled.isBefore(now)) {
          scheduled = scheduled.add(const Duration(days: 1));
        }

        await notificationsPlugin.zonedSchedule(
          id++,
          'حان وقت شرب الماء 💧',
          'درجة الحرارة ${_temperature.round()}°م — اشرب $cupSize مل للوصول لهدفك ($_totalTargetMl مل).',
          scheduled,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'water_reminders_channel',
              'تذكيرات شرب المياه',
              channelDescription: 'تنبيهات دورية لشرب الماء حسب حالة الطقس',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      }
    }
  }

  Future<void> _sendInstantTestNotification() async {
    await notificationsPlugin.show(
      999,
      'تذكير تجريبي: اشرب كوب ماء الآن 💧',
      'طقس اليوم ${_temperature.round()}°م | المتبقي لك: ${max(0, _totalTargetMl - _consumedMl)} مل.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'water_reminders_channel',
          'تذكيرات شرب المياه',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  void _addWater(int ml) {
    final timeStr =
        '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
    setState(() {
      _consumedMl += ml;
      _logs.insert(0, '$timeStr  —  تم شرب $ml مل');
    });
    _saveData();
  }

  void _resetToday() {
    setState(() {
      _consumedMl = 0;
      _logs.clear();
    });
    _saveData();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_consumedMl / _totalTargetMl).clamp(0.0, 1.0);
    final remaining = max(0, _totalTargetMl - _consumedMl);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('رَيّ • التذكير الذكي بالمياه',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'إرسال إشعار تجريبي الآن',
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: _sendInstantTestNotification,
          ),
          IconButton(
            tooltip: 'إعدادات الوزن والوقت',
            icon: const Icon(Icons.tune),
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // بطاقة الطقس والربط الحراري
          Card(
            elevation: 0,
            color: colors.secondaryContainer.withOpacity(0.5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.wb_sunny_rounded,
                          size: 36, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_cityName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15)),
                            Text(
                                'الحرارة: ${_temperature.toStringAsFixed(1)}°م • الرطوبة: $_humidity% ($_weatherDesc)',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: colors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _isLoadingWeather ? null : _fetchLiveWeather,
                        icon: _isLoadingWeather
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.my_location, size: 18),
                        label: const Text('تحديث'),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statChip('الأساسي', '$_baseNeedMl مل'),
                      _statChip('النشاط', '+$_activityBonusMl مل'),
                      _statChip('تعويض الطقس', '+$_weatherBonusMl مل'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // مؤشر التقدم اليومي
          Card(
            elevation: 0,
            color: colors.primaryContainer.withOpacity(0.4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 170,
                        height: 170,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 14,
                          backgroundColor: colors.surfaceContainerHighest,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      Column(
                        children: [
                          Text('${(progress * 100).round()}%',
                              style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.bold,
                                  color: colors.primary)),
                          Text('$_consumedMl / $_totalTargetMl مل',
                              style: const TextStyle(fontSize: 14)),
                          Text('المتبقي: $remaining مل',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _addWater(200),
                        icon: const Icon(Icons.local_drink),
                        label: const Text('+200 مل (كوب)'),
                      ),
                      FilledButton.icon(
                        onPressed: () => _addWater(330),
                        icon: const Icon(Icons.water_drop),
                        label: const Text('+330 مل (قنينة)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _addWater(500),
                        icon: const Icon(Icons.add),
                        label: const Text('+500 مل'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // شريط تفعيل التذكيرات
          SwitchListTile(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            tileColor: colors.surfaceContainerLow,
            title: const Text('تفعيل التذكير التلقائي كل 90 دقيقة',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('من الساعة $_wakeHour:00 صباحاً حتى $_sleepHour:00 مساءً'),
            value: _remindersActive,
            onChanged: (val) async {
              setState(() => _remindersActive = val);
              await _saveData();
              await _scheduleReminders();
            },
          ),
          const SizedBox(height: 16),

          // سجل الشرب اليومي
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('سجل اليوم',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              if (_logs.isNotEmpty)
                TextButton(
                    onPressed: _resetToday, child: const Text('تصفير اليوم')),
            ],
          ),
          if (_logs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                  child: Text('لم تسجل أي كوب ماء بعد اليوم 💧',
                      style: TextStyle(color: Colors.grey))),
            )
          else
            ..._logs.map((entry) => Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(Icons.check_circle, color: colors.primary),
                    title: Text(entry),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تخصيص الاحتياج والطقس اليدوي',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('الوزن: ${_weight.round()} كغم'),
              Slider(
                min: 40,
                max: 150,
                value: _weight,
                onChanged: (v) {
                  setModalState(() => _weight = v);
                  setState(() {});
                },
              ),
              Text('درجة الحرارة (في حال عدم استخدام GPS): ${_temperature.round()}°م'),
              Slider(
                min: 5,
                max: 52,
                value: _temperature,
                onChanged: (v) {
                  setModalState(() => _temperature = v);
                  setState(() {});
                },
              ),
              const Text('مستوى النشاط البدني:'),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'low', label: Text('خفيف')),
                  ButtonSegment(value: 'moderate', label: Text('متوسط')),
                  ButtonSegment(value: 'high', label: Text('عالي')),
                ],
                selected: {_activity},
                onSelectionChanged: (s) {
                  setModalState(() => _activity = s.first);
                  setState(() {});
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await _saveData();
                    await _scheduleReminders();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('حفظ وتحديث التذكيرات'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

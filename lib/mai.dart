import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path. me' as p;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await requestPermissions();
  await initializeBackgroundService();
  runApp(const MotoGpsApp());
}

Future<void> requestPermissions() async {
  await Permission.locationWhenInUse.request();
  await Permission.locationAlways.request();
  await Permission.notification.request();
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationTitle: "Moto GPS Tracker",
      notificationContent: "Traseul este înregistrat în fundal...",
      initialNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onBackgroundServiceStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onBackgroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final dbPath = await getDatabasesPath();
  final database = await openDatabase(
    p.join(dbPath, 'moto_tracks.db'),
    onCreate: (db, version) {
      return db.execute(
        'CREATE TABLE points('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'latitude REAL, '
        'longitude REAL, '
        'altitude REAL, '
        'speed REAL, '
        'timestamp TEXT)',
      );
    },
    version: 1,
  );

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  const LocationSettings locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5,
  );

  Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
    if (position.accuracy > 20) return;

    await database.insert('points', {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'altitude': position.altitude,
      'speed': position.speed,
      'timestamp': position.timestamp.toIso8601String(),
    });

    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        final speedKmH = (position.speed * 3.6).toStringAsFixed(0);
        service.setForegroundNotificationInfo(
          title: "Moto GPS Tracker — Înregistrare activă",
          content: "Viteză curentă: $speedKmH km/h",
        );
      }
    }

    service.invoke('update', {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'speed': position.speed,
    });
  });
}

class GpxExporter {
  static Future<String> generateGpxString() async {
    final dbPath = await getDatabasesPath();
    final database = await openDatabase(p.join(dbPath, 'moto_tracks.db'));
    final List<Map<String, dynamic>> maps = await database.query('points', orderBy: 'id ASC');

    if (maps.isEmpty) {
      throw Exception("Nu există puncte salvate pentru a exporta traseul.");
    }

    final StringBuffer xml = StringBuffer();
    xml.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    xml.writeln('<gpx version="1.1" creator="Moto GPS Tracker" xmlns="http://www.topografix.com/GPX/1/1">');
    xml.writeln('  <metadata>');
    xml.writeln('    <name>Traseu Moto - ${DateTime.now().toIso8601String().split('T').first}</name>');
    xml.writeln('  </metadata>');
    xml.writeln('  <trk>');
    xml.writeln('    <name>Cursa Moto</name>');
    xml.writeln('    <trkseg>');

    for (var row in maps) {
      final lat = row['latitude'];
      final lon = row['longitude'];
      final ele = row['altitude'] ?? 0.0;
      final time = row['timestamp'];
      final speed = row['speed'] ?? 0.0;

      xml.writeln('      <trkpt lat="$lat" lon="$lon">');
      xml.writeln('        <ele>$ele</ele>');
      xml.writeln('        <time>$time</time>');
      xml.writeln('        <extensions>');
      xml.writeln('          <speed>$speed</speed>');
      xml.writeln('        </extensions>');
      xml.writeln('      </trkpt>');
    }

    xml.writeln('    </trkseg>');
    xml.writeln('  </trk>');
    xml.writeln('</gpx>');

    return xml.toString();
  }

  static Future<File> exportAndShare() async {
    final gpxContent = await generateGpxString();
    final tempDir = await getTemporaryDirectory();
    final fileName = 'traseu_moto_${DateTime.now().millisecondsSinceEpoch}.gpx';
    final file = File('${tempDir.path}/$fileName');

    await file.writeAsString(gpxContent);
    await Share.shareXFiles([XFile(file.path)], text: 'Traseul meu GPX înregistrat cu Moto GPS Tracker');
    return file;
  }
}

class MotoGpsApp extends StatelessWidget {
  const MotoGpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const TrackingScreen(),
    );
  }
}

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  bool _isTracking = false;
  bool _isExporting = false;
  double _currentSpeed = 0.0;
  int _pointsCount = 0;
  StreamSubscription? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _checkServiceStatus();

    _serviceSubscription = FlutterBackgroundService().on('update').listen((event) {
      if (event != null && mounted) {
        setState(() {
          _currentSpeed = (event['speed'] ?? 0.0) * 3.6;
        });
        _loadPointsCount();
      }
    });
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await FlutterBackgroundService().isRunning();
    setState(() {
      _isTracking = isRunning;
    });
    _loadPointsCount();
  }

  Future<void> _loadPointsCount() async {
    final dbPath = await getDatabasesPath();
    final database = await openDatabase(p.join(dbPath, 'moto_tracks.db'));
    final result = await database.rawQuery('SELECT COUNT(*) as count FROM points');
    final count = Sqflite.firstIntValue(result) ?? 0;
    if (mounted) {
      setState(() {
        _pointsCount = count;
      });
    }
  }

  Future<void> _toggleTracking() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke('stopService');
      setState(() {
        _isTracking = false;
        _currentSpeed = 0.0;
      });
    } else {
      await service.startService();
      setState(() {
        _isTracking = true;
      });
    }
  }

  Future<void> _exportGpx() async {
    setState(() {
      _isExporting = true;
    });

    try {
      await GpxExporter.exportAndShare();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fișierul GPX a fost generat cu succes!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Eroare export: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _clearData() async {
    final dbPath = await getDatabasesPath();
    final database = await openDatabase(p.join(dbPath, 'moto_tracks.db'));
    await database.delete('points');
    _loadPointsCount();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Istoricul local a fost șters.')),
      );
    }
  }

  @override
  void dispose() {
    _serviceSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moto GPS Tracker'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  children: [
                    Text(
                      _currentSpeed.toStringAsFixed(0),
                      style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold),
                    ),
                    const Text('KM/H', style: TextStyle(fontSize: 18, color: Colors.grey)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Puncte GPS salvate în baza de date: $_pointsCount',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 36),
            ElevatedButton(
              onPressed: _toggleTracking,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 20),
                backgroundColor: _isTracking ? Colors.redDark : Colors.greenDark,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(
                _isTracking ? 'OPREȘTE ÎNREGISTRAREA' : 'PORNEȘTE ÎNREGISTRAREA',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: (_pointsCount > 0 && !_isExporting) ? _exportGpx : null,
              icon: _isExporting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: Text(
                _isExporting ? 'SE GENEREAZĂ GPX...' : 'EXPORTĂ TRASEUL (.GPX)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _clearData,
              child: const Text('Șterge traseul salvat local', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }
}

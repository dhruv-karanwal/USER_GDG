import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

// Screens (import your actual files here)
import 'package:user_gdg/home_page.dart';
import 'package:user_gdg/flood_map_screen.dart';
import 'package:user_gdg/sos_screen.dart';
import 'package:user_gdg/advisory_screen.dart';
import 'package:user_gdg/safe_zone_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const FloodCitizenApp());
}

class FloodCitizenApp extends StatelessWidget {
  const FloodCitizenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flood Safety Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
      ),
      initialRoute: '/map',
      routes: {
        '/': (context) => const HomePage(),
        '/map': (context) => const FloodMapScreen(),
        '/sos': (context) => const SOSScreen(),
        '/advisory': (context) => const AdvisoryScreen(),
        '/safezones': (context) => const SafeZoneScreen(),
      },
    );
  }
}

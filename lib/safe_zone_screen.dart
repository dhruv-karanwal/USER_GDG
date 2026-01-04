import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:user_gdg/safezone_map_screen.dart';

class SafeZoneScreen extends StatefulWidget {
  const SafeZoneScreen({super.key});

  @override
  State<SafeZoneScreen> createState() => _SafeZoneScreenState();
}

class _SafeZoneScreenState extends State<SafeZoneScreen> {
  Position? _userPos;
  bool _isFetchingLocation = false;
  bool _permissionDenied = false;
  bool _permissionPermanentlyDenied = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _checkPermissionAndFetch();
  }

  Future<void> _checkPermissionAndFetch() async {
    setState(() {
      _isFetchingLocation = true;
      _locationError = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _locationError = 'Location services are disabled. Please enable them in system settings.';
          _isFetchingLocation = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        // Permission denied (but not permanently)
        setState(() {
          _permissionDenied = true;
          _permissionPermanentlyDenied = false;
          _isFetchingLocation = false;
        });
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        // Permissions are denied forever, handle appropriately
        setState(() {
          _permissionPermanentlyDenied = true;
          _permissionDenied = false;
          _isFetchingLocation = false;
        });
        return;
      }

      // Permission granted - fetch position
      await _fetchLocation();
    } catch (e) {
      setState(() {
        _locationError = e.toString();
        _isFetchingLocation = false;
      });
    }
  }

  Future<void> _fetchLocation() async {
    setState(() {
      _isFetchingLocation = true;
      _locationError = null;
    });

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() {
        _userPos = pos;
        _isFetchingLocation = false;
        _permissionDenied = false;
        _permissionPermanentlyDenied = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = e.toString();
        _isFetchingLocation = false;
      });
    }
  }

  double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const R = 6371;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);

    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_isFetchingLocation) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_permissionPermanentlyDenied) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Location permission permanently denied. Open app settings to grant permission.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  await Geolocator.openAppSettings();
                },
                child: const Text('Open App Settings'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _checkPermissionAndFetch,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    } else if (_permissionDenied) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Location permission is required to show nearby safe zones. Please allow access.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _checkPermissionAndFetch,
                child: const Text('Request Permission'),
              ),
            ],
          ),
        ),
      );
    } else if (_locationError != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Error getting location: $_locationError', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _checkPermissionAndFetch, child: const Text('Retry')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await Geolocator.openLocationSettings();
                },
                child: const Text('Open Location Settings'),
              ),
            ],
          ),
        ),
      );
    } else if (_userPos == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unable to get location.'),
              const SizedBox(height: 8),
              ElevatedButton(onPressed: _checkPermissionAndFetch, child: const Text('Retry')),
            ],
          ),
        ),
      );
    } else {
      body = StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('safe-zones').snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          /// 🔥 Flatten all zones from all flood docs
          final List<Map<String, dynamic>> zones = [];

          for (final doc in snap.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            if (data['zones'] is List) {
              for (final z in data['zones']) {
                zones.add(Map<String, dynamic>.from(z));
              }
            }
          }

          if (zones.isEmpty) {
            return const Center(child: Text('No safe zones available'));
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: zones.length,
            itemBuilder: (context, index) {
              final zone = zones[index];

              final coords = zone['coordinate'] as List;
              final lat = coords[0];
              final lng = coords[1];

              final dist = _distanceKm(
                _userPos!.latitude,
                _userPos!.longitude,
                lat,
                lng,
              );

              return _SafeZoneCard(
                zone: zone,
                distanceKm: dist,
                onViewMap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SafeZoneMapScreen(
                        zones: zones,
                        userLocation: LatLng(
                          _userPos!.latitude,
                          _userPos!.longitude,
                        ),
                        selectedIndex: index, // show selected zone
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Safe Zones')),
      body: body,
    );
  }
}
class _SafeZoneCard extends StatelessWidget {
  final Map<String, dynamic> zone;
  final double distanceKm;
  final VoidCallback onViewMap;

  const _SafeZoneCard({
    required this.zone,
    required this.distanceKm,
    required this.onViewMap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zone['name'],
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text('${zone['type']} • ${zone['category']}'),
            const SizedBox(height: 6),
            Text(
              '${distanceKm.toStringAsFixed(2)} km away',
              style: const TextStyle(color: Colors.green),
            ),
            const SizedBox(height: 6),
            Text('Capacity: ${zone['capacity']}'),
            const SizedBox(height: 6),
            Text('Status: ${zone['operationalStatus']}'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onViewMap,
                icon: const Icon(Icons.map),
                label: const Text('View on Map'),
              ),
            )
          ],
        ),
      ),
    );
  }
}

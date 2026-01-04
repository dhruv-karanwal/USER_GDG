import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

// Add your OpenRouteService API key here
const String ORS_API_KEY = 'eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjZiMzQ4NjAzNjAzYzQ5OWNhOWJkMTMyNWFmZDg0OGUwIiwiaCI6Im11cm11cjY0In0=';

class SafeZoneMapScreen extends StatefulWidget {
  final List<Map<String, dynamic>> zones;
  final LatLng userLocation;
  final int selectedIndex;

  const SafeZoneMapScreen({
    super.key,
    required this.zones,
    required this.userLocation,
    this.selectedIndex = 0,
  });

  @override
  State<SafeZoneMapScreen> createState() => _SafeZoneMapScreenState();
}

class _SafeZoneMapScreenState extends State<SafeZoneMapScreen> {
  late List<Map<String, dynamic>> zones;
  late int selectedIndex;
  final MapController _mapController = MapController();
  List<LatLng> _routePoints = [];
  bool _isLoadingRoute = false;

  @override
  void initState() {
    super.initState();
    zones = List<Map<String, dynamic>>.from(widget.zones);
    selectedIndex = widget.selectedIndex.clamp(0, zones.length - 1);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusOnSelected();
      _fetchRouteToSelected();
    });
  }

  LatLng _zoneLatLng(int idx) {
    final c = zones[idx]['coordinate'];
    return LatLng((c[0] as num).toDouble(), (c[1] as num).toDouble());
  }

  void _focusOnSelected() {
    final latlng = _zoneLatLng(selectedIndex);
    _mapController.move(latlng, 13);
  }

  Future<void> _fetchRouteToSelected() async {
    setState(() => _isLoadingRoute = true);

    try {
      final start = [
        widget.userLocation.longitude,
        widget.userLocation.latitude,
      ];

      final dest = _zoneLatLng(selectedIndex);

      final end = [
        dest.longitude,
        dest.latitude,
      ];

      final uri = Uri.parse(
        'https://api.openrouteservice.org/v2/directions/driving-car/geojson',
      );

      final response = await http.post(
        uri,
        headers: {
          'Authorization': ORS_API_KEY,
          'Content-Type': 'application/json',
          'Accept': 'application/geo+json', // 🔥 THIS FIXES 406
        },
        body: jsonEncode({
          "coordinates": [start, end],
        }),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'ORS ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body);

      final List coords =
          data['features'][0]['geometry']['coordinates'];

      setState(() {
        _routePoints = coords
            .map<LatLng>(
              (c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ),
            )
            .toList();
        _isLoadingRoute = false;
      });
    } catch (e) {
      setState(() => _isLoadingRoute = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Route error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedZone = zones[selectedIndex];
    final selectedPoint = _zoneLatLng(selectedIndex);

    return Scaffold(
      appBar: AppBar(title: const Text('Safe Zones Map')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: selectedPoint,
              initialZoom: 13,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key=xv0FjIRz99TJBdP08drv',
                userAgentPackageName: 'com.example.user_gdg',
              ),

              // Route polyline
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(points: _routePoints, color: Colors.blue, strokeWidth: 4),
                  ],
                ),

              // zone markers
              MarkerLayer(
                markers: zones.asMap().entries.map((entry) {
                  final i = entry.key;
                  final z = entry.value;
                  final pt = LatLng((z['coordinate'][0] as num).toDouble(), (z['coordinate'][1] as num).toDouble());
                  final isSelected = i == selectedIndex;
                  return Marker(
                    point: pt,
                    width: isSelected ? 56 : 44,
                    height: isSelected ? 56 : 44,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          selectedIndex = i;
                        });
                        _focusOnSelected();
                        _fetchRouteToSelected();
                      },
                      child: Icon(
                        Icons.location_on,
                        color: isSelected ? Colors.green : Colors.red,
                        size: isSelected ? 48 : 36,
                      ),
                    ),
                  );
                }).toList(),
              ),

              // user marker
              MarkerLayer(
                markers: [
                  Marker(
                    point: widget.userLocation,
                    width: 36,
                    height: 36,
                    child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 36),
                  ),
                ],
              ),
            ],
          ),

          // top info and controls
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Row(
              children: [
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(child: Text(selectedZone['name'] ?? 'Selected zone')),
                          if (_isLoadingRoute) const SizedBox(width: 8),
                          if (_isLoadingRoute) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    _focusOnSelected();
                  },
                  child: const Icon(Icons.my_location),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}

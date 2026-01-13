import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:user_gdg/advisory_screen.dart';
import 'package:user_gdg/safe_zone_screen.dart';

// TODO: Put your MapTiler API key here (or load from a secure place)
const String MAPTILER_API_KEY = 'xv0FjIRz99TJBdP08drv';

class FloodMapScreen extends StatefulWidget {
  const FloodMapScreen({super.key});

  @override
  State<FloodMapScreen> createState() => _FloodMapScreenState();
}

class _FloodMapScreenState extends State<FloodMapScreen> with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  List<Polygon> _polygons = [];
  List<Marker> _markers = [];
  String _selectedLayer = '';
  bool _isLoading = false;
  
  // Spec Alignment: User Location
  LatLng? _userLocation;
  StreamSubscription<Position>? _positionStream;

  // FAB Animation
  late AnimationController _fabAnimationController;
  late Animation<double> _fabExpandAnimation;
  late Animation<double> _fabRotateAnimation;
  bool _isFabOpen = false;

  // SOS State
  bool _sendingSOS = false;
  String? _activeSOSId; // Tracks the current active SOS document ID

  @override
  void initState() {
    super.initState();
    // No initial layer loaded
    
    // Start tracking user location
    _startLocationUpdates();

    // Initialize FAB Animation
    _fabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fabExpandAnimation = CurvedAnimation(
      parent: _fabAnimationController,
      curve: Curves.fastOutSlowIn,
    );
    _fabRotateAnimation = Tween<double>(begin: 0.0, end: 0.5).animate(
      CurvedAnimation(
        parent: _fabAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _fabAnimationController.dispose();
    super.dispose();
  }

  Future<void> _startLocationUpdates() async {
    // Check permission quietly
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Requesting here might be intrusive on immediate launch, 
      // but "Where am I?" is a core q. Let's try requesting if denied.
      await Geolocator.requestPermission();
    }
    
    try {
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, 
          distanceFilter: 10,
        ),
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _userLocation = LatLng(position.latitude, position.longitude);
          });
        }
      });
    } catch (e) {
      debugPrint('Error getting location stream: $e');
    }
  }

  void _toggleFab() {
    setState(() {
      _isFabOpen = !_isFabOpen;
      if (_isFabOpen) {
        _fabAnimationController.forward();
      } else {
        _fabAnimationController.reverse();
      }
    });
  }

  Future<void> _sendSOS() async {
    try {
      setState(() => _sendingSOS = true);

      // 1️⃣ Check location service
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw 'Location services are disabled';
      }

      // 2️⃣ Permission handling
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw 'Location permission denied';
      }

      // 3️⃣ Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 4️⃣ Push EXACT rescue request structure
      final docRef = await FirebaseFirestore.instance.collection('rescue_requests').add({
        'location': 'User SOS Location',
        'lat': position.latitude,
        'lng': position.longitude,
        'status': 'PENDING',
        'priority': 'High',
        'description':
            'Emergency SOS triggered by user. Immediate rescue required.',
        'createdAt': FieldValue.serverTimestamp(),
        'source': 'MOBILE_SOS',
      });

      setState(() {
        _activeSOSId = docRef.id;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'SOS sent successfully! Help is on the way.',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('SOS ERROR → $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Failed to send SOS: $e',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingSOS = false);
    }
  }

  /// Process coordinates and create map elements
  Future<void> _processCoordinates(List<dynamic> coords, String layer) async {
    print('Total coordinates: ${coords.length}');

    if (coords.isNotEmpty) {
      print('First coordinate: ${coords.first}');
      if (coords.length > 1) {
        print('Second coordinate: ${coords[1]}');
      }
    }

    List<LatLng> points = [];

    // Parse each coordinate
    for (var i = 0; i < coords.length; i++) {
      final latLng = _parseCoordinate(coords[i]);
      if (latLng != null) {
        points.add(latLng);
      } else {
        print('Failed to parse coordinate at index $i: ${coords[i]}');
      }
    }

    print('Successfully parsed ${points.length} points');

    if (points.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final colors = _getLayerColors(layer);

    // For certain layers, show individual markers
    if (_shouldShowMarkers(layer)) {
      _markers = [];
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        
        // Extract metadata if available (Safe Zones)
        Map<String, dynamic> metadata = {};
        if (layer == 'safe_zones_relief' && i < coords.length && coords[i] is Map) {
          metadata = coords[i] as Map<String, dynamic>;
        }

        _markers.add(
          Marker(
            point: point,
            width: 40,
            height: 40,
            child: GestureDetector(
              onTap: () {
                if (layer == 'safe_zones_relief') {
                  _showSafeZoneDetails(point, metadata);
                }
              },
              child: Icon(
                layer == 'safe_zones_relief'
                    ? Icons.health_and_safety
                    : layer == 'household_impact'
                        ? Icons.home
                        : Icons.location_on,
                color: colors['border'],
                size: 35,
              ),
            ),
          ),
        );
      }
      print('Created ${_markers.length} markers');
    }

    // Create polygon for area visualization (if enough points)
    if (points.length >= 3) {
      final polygon = Polygon(
        points: points,
        color: colors['fill']!,
        borderColor: colors['border']!,
        borderStrokeWidth: 2.0,
      );
      _polygons = [polygon];
      print('Created polygon with ${points.length} points');
    }

    setState(() => _isLoading = false);

    // Fit bounds to show the complete region
    if (points.isNotEmpty) {
      final latitudes = points.map((p) => p.latitude);
      final longitudes = points.map((p) => p.longitude);
      final south = latitudes.reduce(min);
      final north = latitudes.reduce(max);
      final west = longitudes.reduce(min);
      final east = longitudes.reduce(max);
      
      _fitMapToBounds(south, north, west, east);
    }
  }

  void _fitBounds(List<LatLng> points) {
     if (points.isEmpty) return;
      final latitudes = points.map((p) => p.latitude);
      final longitudes = points.map((p) => p.longitude);
      final south = latitudes.reduce(min);
      final north = latitudes.reduce(max);
      final west = longitudes.reduce(min);
      final east = longitudes.reduce(max);
      
      _fitMapToBounds(south, north, west, east);
  }

  void _fitMapToBounds(double south, double north, double west, double east) {
      print('Bounds: South=$south, North=$north, West=$west, East=$east');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          final center = LatLng(
            (south + north) / 2,
            (west + east) / 2,
          );

          // Calculate appropriate zoom level based on bounds
          final latDiff = (north - south).abs();
          final lngDiff = (east - west).abs();
          final maxDiff = max(latDiff, lngDiff);

          double zoom = 11;
          if (maxDiff > 2)
            zoom = 8;
          else if (maxDiff > 1)
            zoom = 9;
          else if (maxDiff > 0.5)
            zoom = 10;
          else if (maxDiff > 0.1)
            zoom = 12;
          else if (maxDiff > 0.05)
            zoom = 13;
          else
            zoom = 14;

          print('Moving map to center: $center with zoom: $zoom');
          _mapController.move(center, zoom);
        } catch (e) {
          print('Error moving map: $e');
        }
      });
  }

  /// Determines if a layer should show individual point markers
  bool _shouldShowMarkers(String layer) {
    return layer == 'safe_zones_relief' ||
        layer == 'household_impact' ||
        layer == 'disaster_tour';
  }

  /// Gets color scheme for each layer type
  Map<String, Color> _getLayerColors(String layer) {
    switch (layer) {
      case 'after_flood_extent':
        return {'fill': Colors.red.withOpacity(0.4), 'border': Colors.red};
      case 'before_flood':
        return {'fill': Colors.blue.withOpacity(0.3), 'border': Colors.blue};
      case 'disaster_tour':
        return {'fill': Colors.orange.withOpacity(0.4), 'border': Colors.orange};
      case 'household_impact':
        return {'fill': Colors.purple.withOpacity(0.4), 'border': Colors.purple};
      case 'rainfall_severity':
        return {'fill': Colors.indigo.withOpacity(0.4), 'border': Colors.indigo};
      case 'river_basin_impact':
        return {'fill': Colors.cyan.withOpacity(0.4), 'border': Colors.cyan};
      case 'safe_zones_relief':
        return {'fill': Colors.green.withOpacity(0.4), 'border': Colors.green};
      case 'urban_flood_hotspots':
        return {
          'fill': Colors.deepOrange.withOpacity(0.4),
          'border': Colors.deepOrange
        };
      case 'vegetation_agriculture_loss':
        return {'fill': Colors.brown.withOpacity(0.4), 'border': Colors.brown};
      default:
        return {'fill': Colors.grey.withOpacity(0.3), 'border': Colors.grey};
    }
  }

  /// Parse coordinate from the Firestore format. Supports:
  /// - top-level maps: {lat: x, lng: y} or {lng: x, lat: y}
  /// - nested maps: {0: {lat: x, lng: y}}
  /// - arrays: [lat, lng]
  LatLng? _parseCoordinate(dynamic item) {
    try {
      if (item is Map) {
        // 1) Direct top-level {lat: ..., lng: ...}
        final num? latTop = item['lat'] ?? item['latitude'];
        final num? lngTop = item['lng'] ?? item['longitude'] ?? item['long'];
        if (latTop != null && lngTop != null) {
          return LatLng(latTop.toDouble(), lngTop.toDouble());
        }

        // 2) Maybe the map is keyed by indices: {0: {...}} or {0: [lat,lng]}
        var value = item.values.first;

        if (value is Map) {
          final num? lat = value['lat'] ?? value['latitude'];
          final num? lng = value['lng'] ?? value['longitude'] ?? value['long'];
          if (lat != null && lng != null) {
            return LatLng(lat.toDouble(), lng.toDouble());
          }
        } else if (value is List && value.length >= 2) {
          return LatLng((value[0] as num).toDouble(), (value[1] as num).toDouble());
        }
      } else if (item is List && item.length >= 2) {
        // Direct array format: [lat, lng]
        return LatLng((item[0] as num).toDouble(), (item[1] as num).toDouble());
      }
    } catch (e) {
      print('Error parsing coordinate: $e for item: $item');
    }
    return null;
  }

  // Hardcoded Safe Zone Data from KML
  final List<Map<String, dynamic>> _kmlSafeZones = [
    {
      'name': 'Relief Camp: UC College, Aluva',
      'description': 'Major relief camp housing thousands of evacuated people.',
      'category': 'Relief Camp',
      'status': 'Open',
      'lat': 10.1250,
      'lng': 76.3315,
      'capacity': 2500,
    },
    {
      'name': 'Relief Camp: St. Berchmans College, Changanassery',
      'description': 'Sheltered many from Kuttanad region.',
      'category': 'Relief Camp',
      'status': 'Open',
      'lat': 9.4442,
      'lng': 76.5414,
      'capacity': 1200,
    },
    {
      'name': 'Amrita Institute of Medical Sciences',
      'description': 'Major hospital providing emergency care.',
      'category': 'Hospital',
      'status': 'Active',
      'lat': 10.0331,
      'lng': 76.2917,
      'capacity': 'High',
    },
    {
      'name': 'Medical College, Kottayam',
      'description': 'Key healthcare facility for flood victims.',
      'category': 'Hospital',
      'status': 'Active',
      'lat': 9.6190,
      'lng': 76.5511,
      'capacity': 'High',
    }
  ];

  Future<void> _loadLayer(String layer) async {
    setState(() {
      _isLoading = true;
      _polygons = [];
      _markers = [];
    });

    // Special handling for Safe Zones: Load from local KML data
    if (layer == 'safe_zones_relief') {
      print('Loading Hardcoded Safe Zones from KML data...');
      await Future.delayed(const Duration(milliseconds: 500)); // Simulate load
      
      List<LatLng> points = [];
      _markers = [];
      
      for (final zone in _kmlSafeZones) {
        final point = LatLng(zone['lat'] as double, zone['lng'] as double);
        points.add(point);
        
        _markers.add(
          Marker(
            point: point,
            width: 45,
            height: 45,
            child: GestureDetector(
              onTap: () {
                _showSafeZoneDetails(point, zone);
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                     BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
                  ]
                ),
                child: Icon(
                  zone['category'] == 'Hospital' 
                      ? Icons.local_hospital 
                      : Icons.holiday_village, // Tent/Camp icon
                  color: zone['category'] == 'Hospital' ? Colors.red : Colors.green,
                  size: 30,
                ),
              ),
            ),
          ),
        );
      }
      
      // Fit bounds
      if (points.isNotEmpty) {
        _fitBounds(points);
      }
      
      setState(() => _isLoading = false);
      return;
    }

    try {
      print('\n=== Fetching layer: $layer ===');

      final firestore = FirebaseFirestore.instance;

      // Correct path based on your Firestore structure:
      // floods (collection) -> kerala-flood (document) -> layer_name (collection) -> points (document)
      final docRef = firestore
          .collection('floods')
          .doc('kerela-flood')
          .collection(layer)
          .doc('points');

      print('Fetching from path: ${docRef.path}');

      final doc = await docRef.get();

      print('Document exists: ${doc.exists}');

      // If document doesn't exist, list all documents in the collection

      if (!doc.exists) {
        print('Document does not exist for layer: $layer');
        setState(() => _isLoading = false);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No data found for layer: $layer')),
          );
        }
        return;
      }

      final data = doc.data();
      print('Document fields: ${data?.keys.toList()}');

      // Get the coordinates array
      final coords = (data?['coordinates'] as List<dynamic>?) ?? [];
      
      _processCoordinates(coords, layer);

    } catch (e, stackTrace) {
      print('Error loading layer: $e');
      print('Stack trace: $stackTrace');
      setState(() {
        _polygons = [];
        _markers = [];
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading layer: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }



  void _showSafeZoneDetails(LatLng point, Map<String, dynamic> data) {
    // Calculate distance if user location is known
    String distanceStr = 'Unknown distance';
    if (_userLocation != null) {
      final Distance distance = const Distance();
      final double km = distance.as(LengthUnit.Kilometer, _userLocation!, point);
      distanceStr = '${km.toStringAsFixed(1)} km away';
    }

    final String name = data['name'] ?? 'Safe Zone';
    final String status = data['status'] ?? 'Open';
    final String category = data['category'] ?? 'Emergency Shelter';
    final String capacity = data['capacity']?.toString() ?? 'N/A';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
             BoxShadow(color: Colors.black26, blurRadius: 10, spreadRadius: 2),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Icon(
                  category == 'Hospital' ? Icons.local_hospital : Icons.holiday_village,
                  color: category == 'Hospital' ? Colors.redAccent : Colors.greenAccent, 
                  size: 28
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        category,
                        style: TextStyle(color: Colors.grey[400], fontSize: 13),
                      ),
                       const SizedBox(height: 4),
                      if (data['description'] != null)
                        Text(
                          data['description'],
                          style: TextStyle(color: Colors.grey[500], fontSize: 12, fontStyle: FontStyle.italic),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: status == 'Open' ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: status == 'Open' ? Colors.green : Colors.red),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      color: status == 'Open' ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                _buildInfoBadge(Icons.directions_walk, distanceStr),
                const SizedBox(width: 12),
                _buildInfoBadge(Icons.people, 'Capacity: $capacity'),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent[700],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  // TODO: Implement turn-by-turn if requested, for now just shows details
                },
                icon: const Icon(Icons.directions),
                label: const Text('GET DIRECTIONS'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBadge(IconData icon, String text) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.blue[200], size: 20),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildFabAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Label
          Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.grey[800],
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Mini FAB
          FloatingActionButton(
            heroTag: label, // Unique tag for each FAB
            onPressed: () {
              _toggleFab();
              onTap();
            },
            backgroundColor: color,
            foregroundColor: Colors.white,
            elevation: 4,
            mini: true,
            shape: const CircleBorder(),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, // Removes extra padding
            child: Icon(icon, size: 20),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flood Zones (MapTiler)'),
        actions: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_polygons.isNotEmpty || _markers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: Colors.black12, blurRadius: 4),
                      ],
                    ),
                    child: Text(
                      '${_polygons.isNotEmpty ? "${_polygons.first.points.length} points" : ""}'
                      '${_markers.isNotEmpty ? "${_markers.length} markers" : ""}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[800], fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              Expanded(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(10.0, 76.2),
                    initialZoom: 9,
                    maxZoom: 18,
                    minZoom: 5,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=$MAPTILER_API_KEY',
                      userAgentPackageName: 'com.example.user_gdg',
                    ),
                    if (_polygons.isNotEmpty) PolygonLayer(polygons: _polygons),
                    if (_markers.isNotEmpty) MarkerLayer(markers: _markers),
                    
                    // User Location Marker (Blue Pulse)
                    if (_userLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _userLocation!,
                            width: 20,
                            height: 20,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.9),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.blue.withOpacity(0.4),
                                    blurRadius: 8,
                                    spreadRadius: 4,
                                  )
                                ]
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          
          // Spec Alignment: Trust & Online Status Indicator (Top Center)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.verified_user, color: Colors.blue, size: 14),
                    const SizedBox(width: 6),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'OFFICIAL DISASTER DATA',
                          style: TextStyle(
                            color: Colors.white, 
                            fontSize: 10, 
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          'Updates: Live • Online', 
                          style: TextStyle(
                            color: Colors.greenAccent[400], 
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          // Spec Alignment: Persistent SOS Status (Bottom Left)
          if (_sendingSOS)
             Positioned(
              bottom: 24,
              left: 24,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.4),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'SOS SIGNAL: SENDING...',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
          // Active SOS Status Card (Stream)
          if (!_sendingSOS && _activeSOSId != null)
            Positioned(
              bottom: 24,
              left: 20,
              right: 120, // Leave generous space for FAB on the right
              child: StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('rescue_requests')
                    .doc(_activeSOSId)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData || !snapshot.data!.exists) {
                     return const SizedBox.shrink();
                  }

                  final data = snapshot.data!.data() as Map<String, dynamic>;
                  final status = data['status'] ?? 'PENDING';
                  
                  return GestureDetector(
                    onTap: () => _showSOSDetails(data),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _buildSOSStatusCard(status),
                    ),
                  );
                },
              ),
            ),

          // Expandable FAB Overlay
          if (_isFabOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleFab,
                child: Container(
                  color: Colors.black.withOpacity(0.5),
                ),
              ),
            ),
            
          // Floating Action Button & Menu
          Positioned(
            bottom: 24,
            right: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizeTransition(
                  sizeFactor: _fabExpandAnimation,
                  axis: Axis.vertical,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _buildFabAction(
                        icon: Icons.shield_outlined,
                        label: 'Safe Zones',
                        color: Colors.green,
                        onTap: () {
                          setState(() => _selectedLayer = 'safe_zones_relief');
                          _loadLayer('safe_zones_relief');
                        },
                      ),
                      _buildFabAction(
                        icon: Icons.warning_amber_rounded,
                        label: 'Advisories',
                        color: Colors.orange,
                        onTap: () => Navigator.pushNamed(context, '/advisory'),
                      ),
                      _buildFabAction(
                        icon: _sendingSOS ? Icons.hourglass_top : Icons.sos,
                        label: 'Send SOS',
                        color: Colors.red,
                        onTap: _sendingSOS ? () {} : _sendSOS,
                      ),
                    ],
                  ),
                ),
                FloatingActionButton(
                  onPressed: _toggleFab,
                  backgroundColor: Colors.blue.shade800,
                  elevation: 4,
                  child: RotationTransition(
                    turns: _fabRotateAnimation,
                    child: const Icon(Icons.add, size: 32, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
    // --- SOS LIFECYCLE HELPERS ---

  Widget _buildSOSStatusCard(String status) {
    Color cardColor;
    Color textColor;
    String statusText;
    IconData icon;

    switch (status.toUpperCase()) {
      case 'PENDING':
        cardColor = Colors.orange.shade800;
        textColor = Colors.white;
        statusText = 'SOS PENDING';
        icon = Icons.access_time_filled;
        break;
      case 'ACKNOWLEDGED':
        cardColor = Colors.blue.shade700;
        textColor = Colors.white;
        statusText = 'ASSISTANCE ON WAY'; // User friendly text
        icon = Icons.verified;
        break;
      case 'IN_PROGRESS':
        cardColor = Colors.yellow.shade700;
        textColor = Colors.black87;
        statusText = 'RESCUE IN PROGRESS';
        icon = Icons.directions_run;
        break;
      case 'RESOLVED':
        cardColor = Colors.green.shade700;
        textColor = Colors.white;
        statusText = 'SOS RESOLVED';
        icon = Icons.check_circle;
        break;
      default:
        cardColor = Colors.grey.shade800;
        textColor = Colors.white;
        statusText = 'SOS SENT';
        icon = Icons.error_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 6,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pulse animation for non-resolved states
          if (status != 'RESOLVED') ...[
            SizedBox(
              width: 16, 
              height: 16, 
              child: CircularProgressIndicator(strokeWidth: 2, color: textColor)
            ),
            const SizedBox(width: 12),
          ] else ...[
             Icon(icon, color: textColor, size: 20),
             const SizedBox(width: 8),
          ],
          Text(
            statusText,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  void _showSOSDetails(Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'SOS Request Details',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildDetailRow(Icons.access_time, 'Sent', _formatTimestamp(data['createdAt'])),
            const SizedBox(height: 12),
            _buildDetailRow(Icons.location_on, 'Location', '${data['lat'].toStringAsFixed(4)}, ${data['lng'].toStringAsFixed(4)}'),
            const SizedBox(height: 12),
            _buildDetailRow(Icons.info_outline, 'Status', data['status'] ?? 'PENDING'),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.security, color: Colors.orangeAccent),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Your location has been shared with official disaster response teams.',
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return 'Just now';
    if (timestamp is Timestamp) {
      final dt = timestamp.toDate();
      return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return 'Just now';
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey[400], size: 20),
        const SizedBox(width: 12),
        Text('$label: ', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
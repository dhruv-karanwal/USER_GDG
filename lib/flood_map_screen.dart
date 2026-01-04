import 'dart:math';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// TODO: Put your MapTiler API key here (or load from a secure place)
const String MAPTILER_API_KEY = 'xv0FjIRz99TJBdP08drv';

const List<String> kmlLayers = [
  'after_flood_extent',
  'before_flood',
  'disaster_tour',
  'household_impact',
  'rainfall_severity',
  'river_basin_impact',
  'safe_zones_relief',
  'urban_flood_hotspots',
  'vegetation_agriculture_loss',
];

class FloodMapScreen extends StatefulWidget {
  const FloodMapScreen({super.key});

  @override
  State<FloodMapScreen> createState() => _FloodMapScreenState();
}

class _FloodMapScreenState extends State<FloodMapScreen> {
  final MapController _mapController = MapController();
  List<Polygon> _polygons = [];
  List<Marker> _markers = [];
  String _selectedLayer = kmlLayers.first;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadLayer(_selectedLayer);
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
      _markers = points.map((point) {
        return Marker(
          point: point,
          width: 40,
          height: 40,
          child: Icon(
            layer == 'safe-zones-relief' 
                ? Icons.health_and_safety 
                : layer == 'household_impact'
                    ? Icons.home
                    : Icons.location_on,
            color: colors['border'],
            size: 35,
          ),
        );
      }).toList();
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
          if (maxDiff > 2) zoom = 8;
          else if (maxDiff > 1) zoom = 9;
          else if (maxDiff > 0.5) zoom = 10;
          else if (maxDiff > 0.1) zoom = 12;
          else if (maxDiff > 0.05) zoom = 13;
          else zoom = 14;
          
          print('Moving map to center: $center with zoom: $zoom');
          _mapController.move(center, zoom);
        } catch (e) {
          print('Error moving map: $e');
        }
      });
    }
  }

  /// Determines if a layer should show individual point markers
  bool _shouldShowMarkers(String layer) {
    return layer == 'safe-zones-relief' || 
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
      case 'safe-zones-relief':
        return {'fill': Colors.green.withOpacity(0.4), 'border': Colors.green};
      case 'urban_flood_hotspots':
        return {'fill': Colors.deepOrange.withOpacity(0.4), 'border': Colors.deepOrange};
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

  /// Loads the `points` document for the given layer from Firestore
  Future<void> _loadLayer(String layer) async {
    setState(() {
      _isLoading = true;
      _polygons = [];
      _markers = [];
    });

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
        _markers = points.map((point) {
          return Marker(
            point: point,
            width: 40,
            height: 40,
            child: Icon(
              layer == 'safe-zones-relief' 
                  ? Icons.health_and_safety 
                  : layer == 'household_impact'
                      ? Icons.home
                      : Icons.location_on,
              color: colors['border'],
              size: 35,
            ),
          );
        }).toList();
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
            if (maxDiff > 2) zoom = 8;
            else if (maxDiff > 1) zoom = 9;
            else if (maxDiff > 0.5) zoom = 10;
            else if (maxDiff > 0.1) zoom = 12;
            else if (maxDiff > 0.05) zoom = 13;
            else zoom = 14;
            
            print('Moving map to center: $center with zoom: $zoom');
            _mapController.move(center, zoom);
          } catch (e) {
            print('Error moving map: $e');
          }
        });
      }
      
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                const Text('Layer:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: _selectedLayer,
                    isExpanded: true,
                    items: kmlLayers.map((l) {
                      return DropdownMenuItem(
                        value: l,
                        child: Text(
                          l.replaceAll('_', ' ').replaceAll('-', ' ').toUpperCase(),
                          style: const TextStyle(fontSize: 12),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      setState(() => _selectedLayer = val);
                      _loadLayer(val);
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_polygons.isEmpty && _markers.isEmpty && !_isLoading)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No data available for this layer',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_polygons.isNotEmpty || _markers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                '${_polygons.isNotEmpty ? "${_polygons.first.points.length} points" : ""}'
                '${_markers.isNotEmpty ? "${_markers.length} markers" : ""}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
                  urlTemplate: 'https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=$MAPTILER_API_KEY',
                  userAgentPackageName: 'com.example.user_gdg',
                ),
                if (_polygons.isNotEmpty)
                  PolygonLayer(polygons: _polygons),
                if (_markers.isNotEmpty)
                  MarkerLayer(markers: _markers),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
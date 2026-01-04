import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class AdvisoryScreen extends StatelessWidget {
  const AdvisoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final advisoryRef = FirebaseDatabase.instance.ref('advisories/current');

    return Scaffold(
      appBar: AppBar(title: const Text('Live Advisory')),
      body: StreamBuilder<DatabaseEvent>(
        stream: advisoryRef.onValue,
        builder: (context, snapshot) {
          // Error state
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          // Loading state
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final event = snapshot.data;
          if (event == null || event.snapshot.value == null) {
            return const Center(
              child: Text(
                'No active advisory',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          final raw = event.snapshot.value;

          if (raw is! Map) {
            // If the structure isn't a map we can't read the fields reliably
            return const Center(
              child: Text(
                'No active advisory',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          final Map<dynamic, dynamic> data = raw as Map<dynamic, dynamic>;

          // Robustly parse isActive (accepts bool, number, or string)
          final dynamic isActiveRaw = data['isActive'];
          bool isActive = false;
          if (isActiveRaw is bool) {
            isActive = isActiveRaw;
          } else if (isActiveRaw is num) {
            isActive = isActiveRaw != 0;
          } else if (isActiveRaw is String) {
            isActive = isActiveRaw.toLowerCase() == 'true';
          }

          if (!isActive) {
            return const Center(
              child: Text(
                'No active advisory',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          final String message = (data['message'] ?? '').toString();
          final String type = (data['type'] ?? 'Information').toString();

          // Parse timestamp robustly (accepts int, string, or num). If seconds are provided convert to ms.
          final dynamic tsRaw = data['timestamp'];
          int timestamp = 0;
          if (tsRaw is int) {
            timestamp = tsRaw;
          } else if (tsRaw is num) {
            timestamp = tsRaw.toInt();
          } else if (tsRaw is String) {
            timestamp = int.tryParse(tsRaw) ?? 0;
          }

          DateTime updatedAt = DateTime.fromMillisecondsSinceEpoch(0);
          if (timestamp > 0) {
            // if timestamp looks like seconds, convert to ms
            if (timestamp < 1000000000000) {
              timestamp = timestamp * 1000;
            }
            updatedAt = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
          }

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Card(
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: _typeColor(type),
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          type.toUpperCase(),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _typeColor(type),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Updated at: ${DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal()}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'Warning':
        return Colors.orange;
      case 'Evacuation':
        return Colors.red;
      case 'All Clear':
        return Colors.green;
      default:
        return Colors.blue;
    }
  }
}

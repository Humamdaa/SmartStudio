import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';

class IndexDeviceGate {
  final bool allowed;
  final String? reason;
  final int batteryLevel;
  final int thermalStatus;

  const IndexDeviceGate({
    required this.allowed,
    required this.reason,
    required this.batteryLevel,
    required this.thermalStatus,
  });
}

/// Avoids turning a long gallery scan into a battery/heat problem. Android's
/// WorkManager independently applies battery and storage constraints when the
/// app is in the background.
class DeviceHealthService {
  DeviceHealthService._();
  static final DeviceHealthService instance = DeviceHealthService._();

  static const MethodChannel _channel = MethodChannel('pixmind/device_health');
  final Battery _battery = Battery();

  Future<IndexDeviceGate> canContinueIndexing({
    bool checkLowBattery = true,
    bool checkThermal = true,
  }) async {
    var batteryLevel = 100;
    var isCharging = false;
    var thermalStatus = -1;
    try {
      batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      // A vendor without battery telemetry should not block indexing.
    }
    try {
      thermalStatus = await _channel.invokeMethod<int>('thermalStatus') ?? -1;
    } catch (_) {
      // Android below API 29 has no public thermal status API.
    }

    if (checkLowBattery && !isCharging && batteryLevel < 20) {
      return IndexDeviceGate(
        allowed: false,
        reason: 'توقفت مؤقتًا لأن البطارية أقل من 20٪. اشحن الجهاز ثم تابع.',
        batteryLevel: batteryLevel,
        thermalStatus: thermalStatus,
      );
    }
    if (checkThermal && thermalStatus >= 3) {
      return IndexDeviceGate(
        allowed: false,
        reason:
            'توقفت مؤقتًا حتى يبرد الجهاز، ثم يمكنك المتابعة من نفس المكان.',
        batteryLevel: batteryLevel,
        thermalStatus: thermalStatus,
      );
    }
    return IndexDeviceGate(
      allowed: true,
      reason: null,
      batteryLevel: batteryLevel,
      thermalStatus: thermalStatus,
    );
  }
}

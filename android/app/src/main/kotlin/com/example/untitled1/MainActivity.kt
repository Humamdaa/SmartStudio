package com.example.untitled1

import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth.
// The device-health channel is used by the merged AI indexer to pause on
// serious Android thermal states while still allowing foreground indexing
// below 20% battery.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixmind/device_health"
        ).setMethodCallHandler { call, result ->
            if (call.method != "thermalStatus") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.success(-1)
                return@setMethodCallHandler
            }

            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            result.success(power.currentThermalStatus)
        }
    }
}

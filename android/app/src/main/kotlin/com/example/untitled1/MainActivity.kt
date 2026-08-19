package com.example.untitled1

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

// FlutterFragmentActivity is required by local_auth.
// Device-health and video-frame channels stay tiny/native so PixMind can keep
// heavy AI work local without adding an FFmpeg runtime.
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixmind/video_frame"
        ).setMethodCallHandler { call, result ->
            if (call.method != "extractFrame") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            val timestampUs = call.argument<Number>("timestampUs")?.toLong() ?: 0L
            val maxWidth = call.argument<Number>("maxWidth")?.toInt() ?: 640
            val maxHeight = call.argument<Number>("maxHeight")?.toInt() ?: 640
            val jpegQuality = (call.argument<Number>("jpegQuality")?.toInt() ?: 84)
                .coerceIn(50, 100)

            if (path.isNullOrBlank()) {
                result.error("invalid_path", "Video path is empty", null)
                return@setMethodCallHandler
            }

            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                val raw = retriever.getFrameAtTime(
                    timestampUs,
                    MediaMetadataRetriever.OPTION_CLOSEST
                ) ?: retriever.getFrameAtTime(
                    timestampUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                )

                if (raw == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }

                val scale = minOf(
                    1.0,
                    maxWidth.toDouble() / max(1, raw.width),
                    maxHeight.toDouble() / max(1, raw.height)
                )
                val width = max(1, (raw.width * scale).roundToInt())
                val height = max(1, (raw.height * scale).roundToInt())
                val bitmap = if (width == raw.width && height == raw.height) {
                    raw
                } else {
                    Bitmap.createScaledBitmap(raw, width, height, true)
                }

                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, stream)
                if (bitmap !== raw) bitmap.recycle()
                raw.recycle()
                result.success(stream.toByteArray())
            } catch (error: Throwable) {
                result.error("frame_extract_failed", error.message, null)
            } finally {
                try {
                    retriever.release()
                } catch (_: Throwable) {
                }
            }
        }
    }
}

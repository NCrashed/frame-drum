package dev.ncrashed.frame_drum

import android.Manifest
import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var engine: AudioEngine? = null
    private var pendingPermission: MethodChannel.Result? = null

    // Everything goes through our own channels instead of plugins (which need a
    // native jni/CMake build): storage path, audio I/O, permission, screen lock.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val audio = AudioEngine(this).also { engine = it }

        MethodChannel(messenger, "frame_drum/storage").setMethodCallHandler { call, result ->
            if (call.method == "filesDir") result.success(filesDir.absolutePath) else result.notImplemented()
        }

        EventChannel(messenger, "frame_drum/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                audio.sink = events
            }

            override fun onCancel(arguments: Any?) {
                audio.sink = null
            }
        })

        MethodChannel(messenger, "frame_drum/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(
                    mapOf("sampleRate" to audio.sampleRate, "route" to audio.outputRoute())
                )
                "now" -> result.success(System.nanoTime())
                "requestMic" -> requestMic(result)
                "startMic" -> {
                    if (!hasMic()) {
                        result.error("permission", "RECORD_AUDIO not granted", null)
                    } else {
                        audio.startMic()
                        result.success(null)
                    }
                }
                "stopMic" -> {
                    audio.stopMic()
                    result.success(null)
                }
                "play" -> {
                    val intro = call.argument<FloatArray>("intro") ?: FloatArray(0)
                    val loop = call.argument<FloatArray>("loop") ?: FloatArray(0)
                    audio.play(intro, loop)
                    result.success(null)
                }
                "stopPlay" -> {
                    audio.stopPlay()
                    result.success(null)
                }
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasMic() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMic(result: MethodChannel.Result) {
        if (hasMic()) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MIC_REQUEST) return
        pendingPermission?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
    }

    override fun onDestroy() {
        engine?.stopPlay()
        engine?.stopMic()
        super.onDestroy()
    }

    companion object {
        private const val MIC_REQUEST = 1
    }
}

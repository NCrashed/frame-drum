package dev.ncrashed.frame_drum

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Raw audio I/O for the Dart side. All DSP (onset detection, scoring, sound
 * synthesis) lives in Dart; this class only moves samples and attaches
 * System.nanoTime() timestamps from the audio HAL, so that clicks played and
 * hits heard share one clock.
 *
 * Events sent to [sink]:
 *  - {"type": "mic", "t": Long, "pcm": FloatArray}: t is the capture time of pcm[0].
 *  - {"type": "clock", "t0": Long}: the time frame 0 of the intro leaves the speaker.
 */
class AudioEngine(context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    val sampleRate: Int =
        audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 48000

    @Volatile var sink: EventChannel.EventSink? = null

    @Volatile private var micRunning = false
    private var micThread: Thread? = null

    @Volatile private var playRunning = false
    private var playThread: Thread? = null

    private fun emit(event: Map<String, Any>) {
        main.post { sink?.success(event) }
    }

    fun outputRoute(): String {
        val types = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type }.toSet()
        return when {
            types.any { it in WIRED } -> "wired"
            types.any { it in BLUETOOTH } -> "bluetooth"
            else -> "speaker"
        }
    }

    fun startMic() {
        if (micRunning) return
        micRunning = true
        micThread = Thread({ micLoop() }, "mic").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun stopMic() {
        micRunning = false
        micThread?.join(500)
        micThread = null
    }

    private fun micLoop() {
        // UNPROCESSED skips AGC/noise suppression, which would flatten drum attacks.
        // VOICE_RECOGNITION is the next best thing: no AGC by CDD requirement.
        val unprocessed = audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        val source = if (unprocessed) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val record = try {
            AudioRecord.Builder()
                .setAudioSource(source)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build()
                )
                .setBufferSizeInBytes(maxOf(minBuf * 2, sampleRate / 5 * 4))
                .build()
        } catch (e: SecurityException) {
            micRunning = false
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            micRunning = false
            return
        }

        val chunk = sampleRate / 100
        val ts = AudioTimestamp()
        var framesRead = 0L
        record.startRecording()
        try {
            while (micRunning) {
                val buf = FloatArray(chunk)
                var n = 0
                while (n < chunk && micRunning) {
                    val r = record.read(buf, n, chunk - n, AudioRecord.READ_BLOCKING)
                    if (r <= 0) break
                    n += r
                }
                if (n < chunk) break
                val now = System.nanoTime()
                val t = if (record.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                    ts.nanoTime + (framesRead - ts.framePosition) * 1_000_000_000L / sampleRate
                } else {
                    // No HAL timestamp: assume the chunk ended just now (calibration absorbs the rest).
                    now - chunk * 1_000_000_000L / sampleRate
                }
                framesRead += chunk
                emit(mapOf("type" to "mic", "t" to t, "pcm" to buf))
            }
        } finally {
            record.stop()
            record.release()
        }
    }

    /** Plays [intro] once, then [loop] until [stopPlay]. */
    fun play(intro: FloatArray, loop: FloatArray) {
        stopPlay()
        if (loop.isEmpty()) return
        playRunning = true
        playThread = Thread({ playLoop(intro, loop) }, "play").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun stopPlay() {
        playRunning = false
        playThread?.join(500)
        playThread = null
    }

    private fun playLoop(intro: FloatArray, loop: FloatArray) {
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(minBuf * 2)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        val block = 256
        val out = FloatArray(block)
        val ts = AudioTimestamp()
        var pos = 0L // frames written, counted from intro start
        var lastClock = 0L
        track.play()
        try {
            while (playRunning) {
                for (i in 0 until block) {
                    val p = pos + i
                    out[i] = if (p < intro.size) intro[p.toInt()] else loop[((p - intro.size) % loop.size).toInt()]
                }
                if (track.write(out, 0, block, AudioTrack.WRITE_BLOCKING) < 0) break
                pos += block

                val now = System.nanoTime()
                if (now - lastClock > 250_000_000L && track.getTimestamp(ts) && ts.framePosition > 0) {
                    lastClock = now
                    val t0 = ts.nanoTime - ts.framePosition * 1_000_000_000L / sampleRate
                    emit(mapOf("type" to "clock", "t0" to t0))
                }
            }
        } finally {
            track.pause()
            track.flush()
            track.release()
        }
    }

    companion object {
        private val WIRED = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
        )
        private val BLUETOOTH = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}

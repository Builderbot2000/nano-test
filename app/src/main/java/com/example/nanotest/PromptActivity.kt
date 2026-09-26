package com.example.nanotest

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ModelPreference
import com.google.mlkit.genai.prompt.ModelReleaseStage
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import com.google.mlkit.genai.prompt.generationConfig
import com.google.mlkit.genai.prompt.modelConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File

private const val TAG = "NanoTest"

private val STAGES = mapOf("stable" to ModelReleaseStage.STABLE, "preview" to ModelReleaseStage.PREVIEW)
private val PREFERENCES = mapOf("full" to ModelPreference.FULL, "fast" to ModelPreference.FAST)

/** Process-wide state, so model clients survive between requests. */
private object Nano {
    private val clients = mutableMapOf<String, GenerativeModel>()

    /** stage/preference null = ML Kit's defaults. */
    fun model(stage: String?, preference: String?): GenerativeModel =
        clients.getOrPut("$stage/$preference") {
            if (stage == null && preference == null) return@getOrPut Generation.getClient()
            Generation.getClient(generationConfig {
                modelConfig = modelConfig {
                    stage?.let { releaseStage = STAGES.getValue(it) }
                    preference?.let { this.preference = PREFERENCES.getValue(it) }
                }
            })
        }

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val lock = Mutex()
    var pending = 0
}

/**
 * Runs one request per launch and writes the result to files/results/<id>.json.
 *
 * Extras (all strings): id, mode ("prompt" | "status" | "download"), prompt_b64 (UTF-8, base64),
 * stage ("stable" | "preview"), preference ("full" | "fast"),
 * temperature, top_k, seed, max_tokens.
 *
 * Only mode "download" ever fetches a model; the other modes use what is already on the device.
 */
class PromptActivity : Activity() {

    private lateinit var view: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        view = TextView(this).apply {
            setPadding(48, 48, 48, 48)
            textSize = 14f
            setTextIsSelectable(true)
        }
        setContentView(ScrollView(this).apply { addView(view) })
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        val id = intent.getStringExtra("id")
        // Launched by hand (no id): just show the status on screen.
        val mode = if (id == null) "status" else intent.getStringExtra("mode") ?: "prompt"
        view.text = "Running $mode…"
        Nano.pending++
        Nano.scope.launch {
            // Only prompts are serialized; a long download must not block status checks.
            val result = if (mode == "prompt") Nano.lock.withLock { run(id, mode, intent) } else run(id, mode, intent)
            val json = result.toString(2)
            Log.i(TAG, "result ${result.toString()}")
            if (id != null) writeResult(id, result)
            view.text = json
            Nano.pending--
            if (id != null && Nano.pending == 0) finish()
        }
    }

    private suspend fun run(id: String?, mode: String, intent: Intent): JSONObject {
        val out = JSONObject().put("id", id).put("mode", mode)
        val start = SystemClock.elapsedRealtime()
        try {
            val stage = intent.getStringExtra("stage")?.lowercase()
            val preference = intent.getStringExtra("preference")?.lowercase()
            if (stage != null && stage !in STAGES) return out.put("ok", false).put("error", "stage must be one of ${STAGES.keys}")
            if (preference != null && preference !in PREFERENCES) return out.put("ok", false).put("error", "preference must be one of ${PREFERENCES.keys}")

            val model = Nano.model(stage, preference)
            val status = model.checkStatus()
            out.put("status", statusName(status))
                .put("stage", stage ?: "default")
                .put("preference", preference ?: "default")

            if (mode == "status") {
                // Report every variant, so it's clear which (if any) is already on the device.
                val variants = JSONObject()
                for (s in STAGES.keys) for (p in PREFERENCES.keys) {
                    variants.putSafe("$s/$p") { statusName(Nano.model(s, p).checkStatus()) }
                }
                out.put("variants", variants)
                if (status == FeatureStatus.AVAILABLE) {
                    out.putSafe("base_model") { model.getBaseModelName() }
                    out.putSafe("token_limit") { model.getTokenLimit() }
                    out.putSafe("system_prompt") { model.isSystemPromptAvailable() }
                    out.putSafe("thinking") { model.isThinkingModeAvailable() }
                    out.putSafe("structured_output") { model.isStructuredOutputFeatureAvailable() }
                    out.putSafe("caching") { model.isCachingFeatureAvailable() }
                }
                return out.put("ok", true)
            }

            if (mode == "download") return download(id, model, status, out)

            if (status != FeatureStatus.AVAILABLE) {
                return out.put("ok", false)
                    .put("error", "Model not present on device (status=${statusName(status)}); run with -Download first.")
            }

            val prompt = intent.getStringExtra("prompt_b64")
                ?.let { String(Base64.decode(it, Base64.DEFAULT), Charsets.UTF_8) }
                ?: return out.put("ok", false).put("error", "missing prompt_b64 extra")

            val request = generateContentRequest(TextPart(prompt)) {
                intent.getStringExtra("temperature")?.toFloatOrNull()?.let { temperature = it }
                intent.getStringExtra("top_k")?.toIntOrNull()?.let { topK = it }
                intent.getStringExtra("seed")?.toIntOrNull()?.let { seed = it }
                intent.getStringExtra("max_tokens")?.toIntOrNull()?.let { maxOutputTokens = it }
            }
            val response = model.generateContent(request)
            val candidate = response.candidates.firstOrNull()
            out.put("ok", true)
                .put("text", candidate?.text ?: "")
                .put("finish_reason", candidate?.finishReason)
        } catch (e: GenAiException) {
            Log.w(TAG, "GenAiException", e)
            out.put("ok", false).put("error", e.message).put("error_code", e.errorCode)
        } catch (e: Exception) {
            Log.w(TAG, "request failed", e)
            out.put("ok", false).put("error", "${e.javaClass.simpleName}: ${e.message}")
        }
        return out.put("latency_ms", SystemClock.elapsedRealtime() - start)
    }

    /** Asks AICore to fetch the shared system model; only runs when explicitly requested. */
    private suspend fun download(id: String?, model: GenerativeModel, status: Int, out: JSONObject): JSONObject {
        if (status == FeatureStatus.AVAILABLE) return out.put("ok", true).put("note", "already present")
        if (status == FeatureStatus.UNAVAILABLE) return out.put("ok", false).put("error", "variant not supported on this device")

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        try {
            var total = 0L
            var failure: GenAiException? = null
            model.download().collect { s ->
                when (s) {
                    is DownloadStatus.DownloadStarted -> total = s.bytesToDownload
                    is DownloadStatus.DownloadProgress -> {
                        val progress = JSONObject().put("downloaded", s.totalBytesDownloaded).put("total", total)
                        view.text = "Downloading… ${s.totalBytesDownloaded / 1_000_000} / ${total / 1_000_000} MB"
                        if (id != null) writeFile(id, "progress", progress)
                    }
                    is DownloadStatus.DownloadFailed -> failure = s.e
                    else -> Unit
                }
            }
            failure?.let { throw it }
            return out.put("ok", true)
                .put("bytes", total)
                .put("status", statusName(model.checkStatus()))
        } finally {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun writeResult(id: String, result: JSONObject) = writeFile(id, "json", result)

    private fun writeFile(id: String, ext: String, content: JSONObject) {
        val dir = File(filesDir, "results").apply { mkdirs() }
        // Write then rename, so the host never reads a half-written file.
        val tmp = File(dir, "$id.$ext.tmp")
        tmp.writeText(content.toString())
        tmp.renameTo(File(dir, "$id.$ext"))
    }

    private suspend fun JSONObject.putSafe(key: String, value: suspend () -> Any?) {
        try {
            put(key, value())
        } catch (e: Exception) {
            put(key, "error: ${e.message}")
        }
    }

    private fun statusName(status: Int) = when (status) {
        FeatureStatus.AVAILABLE -> "AVAILABLE"
        FeatureStatus.DOWNLOADABLE -> "DOWNLOADABLE"
        FeatureStatus.DOWNLOADING -> "DOWNLOADING"
        FeatureStatus.UNAVAILABLE -> "UNAVAILABLE"
        else -> "UNKNOWN($status)"
    }
}

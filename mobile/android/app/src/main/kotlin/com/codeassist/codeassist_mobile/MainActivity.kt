package com.codeassist.codeassist_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 华为等机型默认 RecognitionService 是 FakeRecognitionService，
 * SpeechRecognizer.bindService 会直接 SecurityException 闪退。
 * 这里改用系统 RecognizerIntent（弹系统语音界面），不 bind 假服务。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "codeassist/safe_speech"
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognize" -> {
                        if (pendingResult != null) {
                            result.error("busy", "speech already in progress", null)
                            return@setMethodCallHandler
                        }
                        val locale = call.argument<String>("locale") ?: "zh-CN"
                        val prompt = call.argument<String>("prompt") ?: "请说话"
                        startSpeechIntent(locale, prompt, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startSpeechIntent(locale: String, prompt: String, result: MethodChannel.Result) {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
            putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // 尽量走 Google，避开华为 FakeRecognitionService
            setPackage("com.google.android.googlequicksearchbox")
        }

        pendingResult = result
        try {
            startActivityForResult(intent, REQ_SPEECH)
        } catch (_: ActivityNotFoundException) {
            // Google 语音不可用：再试系统默认 Intent（仍走 Activity，不 bind Fake 服务）
            try {
                val fallback = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                    )
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                    putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                }
                startActivityForResult(fallback, REQ_SPEECH)
            } catch (e: ActivityNotFoundException) {
                pendingResult = null
                result.error(
                    "no_speech",
                    "本机没有可用的语音识别（华为假服务不可用）。请安装「谷歌」或系统语音输入后重试。",
                    e.message,
                )
            }
        } catch (e: SecurityException) {
            pendingResult = null
            result.error("security", "语音服务被系统拒绝：${e.message}", null)
        } catch (e: Exception) {
            pendingResult = null
            result.error("failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_SPEECH) return
        val reply = pendingResult ?: return
        pendingResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            val texts = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            val text = texts?.firstOrNull()?.trim().orEmpty()
            reply.success(text)
        } else {
            reply.success("")
        }
    }

    companion object {
        private const val REQ_SPEECH = 9911
    }
}

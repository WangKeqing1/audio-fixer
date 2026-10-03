package com.audiofixer.audio_fixer

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var deviceLibraryBridge: DeviceLibraryBridge? = null
    private var lyricsTranslationBridge: LyricsTranslationBridge? = null
    private var audioPreviewBridge: AudioPreviewBridge? = null
    private var audioInventoryBridge: AudioInventoryBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        disposeAudioInventoryBridge()
        audioInventoryBridge = AudioInventoryBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        disposeAudioPreviewBridge()
        audioPreviewBridge = AudioPreviewBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        disposeDeviceLibraryBridge()
        deviceLibraryBridge = DeviceLibraryBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        disposeLyricsTranslationBridge()
        lyricsTranslationBridge = LyricsTranslationBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        disposeAudioInventoryBridge()
        disposeAudioPreviewBridge()
        disposeLyricsTranslationBridge()
        disposeDeviceLibraryBridge()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        deviceLibraryBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        deviceLibraryBridge?.onActivityResult(requestCode, resultCode, data)
        audioInventoryBridge?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        disposeAudioInventoryBridge()
        disposeAudioPreviewBridge()
        disposeLyricsTranslationBridge()
        disposeDeviceLibraryBridge()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        audioInventoryBridge?.onResume()
        audioPreviewBridge?.onResume()
    }

    override fun onPause() {
        audioInventoryBridge?.onPause()
        audioPreviewBridge?.onPause()
        super.onPause()
    }

    private fun disposeAudioInventoryBridge() {
        audioInventoryBridge?.dispose()
        audioInventoryBridge = null
    }

    private fun disposeAudioPreviewBridge() {
        audioPreviewBridge?.dispose()
        audioPreviewBridge = null
    }

    private fun disposeLyricsTranslationBridge() {
        lyricsTranslationBridge?.dispose()
        lyricsTranslationBridge = null
    }

    private fun disposeDeviceLibraryBridge() {
        deviceLibraryBridge?.dispose()
        deviceLibraryBridge = null
    }
}

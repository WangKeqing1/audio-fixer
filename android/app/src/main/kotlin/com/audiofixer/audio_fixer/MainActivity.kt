package com.audiofixer.audio_fixer

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var deviceLibraryBridge: DeviceLibraryBridge? = null
    private var lyricsTranslationBridge: LyricsTranslationBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }

    override fun onDestroy() {
        disposeLyricsTranslationBridge()
        disposeDeviceLibraryBridge()
        super.onDestroy()
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

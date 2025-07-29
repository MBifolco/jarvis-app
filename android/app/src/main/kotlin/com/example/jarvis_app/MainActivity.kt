package com.example.jarvis_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var l2capPlugin: L2capPlugin? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Register L2CAP plugin
        l2capPlugin = L2capPlugin(flutterEngine)
        l2capPlugin?.register()
    }
    
    override fun onDestroy() {
        l2capPlugin?.dispose()
        super.onDestroy()
    }
}

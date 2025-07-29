package com.example.jarvis_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

class L2capPlugin(private val flutterEngine: FlutterEngine) : 
    MethodChannel.MethodCallHandler, 
    EventChannel.StreamHandler {
    
    companion object {
        private const val TAG = "L2capPlugin"
        private const val METHOD_CHANNEL = "jarvis_app/l2cap"
        private const val EVENT_CHANNEL = "jarvis_app/l2cap_events"
    }
    
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var l2capSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readingJob: Job? = null
    
    private val coroutineScope = CoroutineScope(Dispatchers.IO)
    
    fun register() {
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
        
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(this)
        
        bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
    }
    
    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val address = call.argument<String>("address")
                val psm = call.argument<Int>("psm")
                
                if (address == null || psm == null) {
                    result.error("INVALID_ARGS", "Address and PSM required", null)
                    return
                }
                
                coroutineScope.launch {
                    val success = connectL2cap(address, psm)
                    withContext(Dispatchers.Main) {
                        result.success(success)
                    }
                }
            }
            
            "sendMessage" -> {
                val message = call.argument<String>("message")
                if (message == null) {
                    result.error("INVALID_ARGS", "Message required", null)
                    return
                }
                
                coroutineScope.launch {
                    val success = sendMessage(message)
                    withContext(Dispatchers.Main) {
                        result.success(success)
                    }
                }
            }
            
            "sendBytes" -> {
                val data = call.argument<ByteArray>("data")
                if (data == null) {
                    result.error("INVALID_ARGS", "Data required", null)
                    return
                }
                
                coroutineScope.launch {
                    val success = sendBytes(data)
                    withContext(Dispatchers.Main) {
                        result.success(success)
                    }
                }
            }
            
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            
            else -> result.notImplemented()
        }
    }
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    @Suppress("DEPRECATION")
    private suspend fun connectL2cap(address: String, psm: Int): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                disconnect() // Clean up any existing connection
                
                val device: BluetoothDevice = bluetoothAdapter?.getRemoteDevice(address)
                    ?: throw IOException("Device not found")
                
                Log.d(TAG, "Connecting to L2CAP PSM $psm on device $address")
                
                // Create L2CAP socket
                l2capSocket = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    device.createInsecureL2capChannel(psm)
                } else {
                    // For older Android versions, we'd need reflection or alternative approach
                    throw IOException("L2CAP requires Android Q (API 29) or higher")
                }
                
                // Connect to the socket
                l2capSocket?.connect()
                
                // Get streams
                inputStream = l2capSocket?.inputStream
                outputStream = l2capSocket?.outputStream
                
                // Start reading thread
                startReading()
                
                // Notify Flutter
                sendEvent("connected", null)
                
                Log.d(TAG, "L2CAP connected successfully")
                true
                
            } catch (e: Exception) {
                Log.e(TAG, "L2CAP connection failed", e)
                sendEvent("error", e.message)
                disconnect()
                false
            }
        }
    }
    
    private fun startReading() {
        readingJob = coroutineScope.launch {
            val buffer = ByteArray(1024)
            
            try {
                while (isActive && l2capSocket?.isConnected == true) {
                    val bytesRead = inputStream?.read(buffer) ?: -1
                    
                    if (bytesRead > 0) {
                        val message = String(buffer, 0, bytesRead, Charsets.UTF_8)
                        Log.d(TAG, "Received: $message")
                        sendEvent("message", message)
                    } else if (bytesRead == -1) {
                        break // End of stream
                    }
                }
            } catch (e: IOException) {
                Log.e(TAG, "Error reading from L2CAP", e)
                sendEvent("error", "Read error: ${e.message}")
            }
            
            withContext(Dispatchers.Main) {
                disconnect()
            }
        }
    }
    
    private suspend fun sendMessage(message: String): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val bytes = message.toByteArray(Charsets.UTF_8)
                outputStream?.write(bytes)
                outputStream?.flush()
                Log.d(TAG, "Sent: $message")
                true
            } catch (e: IOException) {
                Log.e(TAG, "Error sending message", e)
                sendEvent("error", "Send error: ${e.message}")
                false
            }
        }
    }
    
    private suspend fun sendBytes(data: ByteArray): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                outputStream?.write(data)
                outputStream?.flush()
                Log.d(TAG, "Sent ${data.size} bytes")
                true
            } catch (e: IOException) {
                Log.e(TAG, "Error sending bytes", e)
                sendEvent("error", "Send error: ${e.message}")
                false
            }
        }
    }
    
    private fun disconnect() {
        readingJob?.cancel()
        
        try {
            inputStream?.close()
            outputStream?.close()
            l2capSocket?.close()
        } catch (e: IOException) {
            Log.e(TAG, "Error closing L2CAP socket", e)
        }
        
        inputStream = null
        outputStream = null
        l2capSocket = null
        
        sendEvent("disconnected", null)
    }
    
    private fun sendEvent(type: String, data: Any?) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(mapOf(
                "type" to type,
                "data" to data
            ))
        }
    }
    
    fun dispose() {
        disconnect()
        coroutineScope.cancel()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }
}
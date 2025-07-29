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
                    Log.d(TAG, "Creating L2CAP channel using createInsecureL2capChannel()")
                    device.createInsecureL2capChannel(psm)
                } else {
                    // For older Android versions, we'd need reflection or alternative approach
                    throw IOException("L2CAP requires Android Q (API 29) or higher")
                }
                
                Log.d(TAG, "L2CAP socket created, attempting connection...")
                
                // Connect to the socket
                l2capSocket?.connect()
                
                Log.d(TAG, "L2CAP socket connected, getting streams...")
                
                // Get streams
                inputStream = l2capSocket?.inputStream
                outputStream = l2capSocket?.outputStream
                
                // Log connection details if available
                l2capSocket?.let { socket ->
                    try {
                        // Try to get MTU or other connection info
                        Log.d(TAG, "L2CAP socket state: isConnected=${socket.isConnected}")
                        Log.d(TAG, "L2CAP input stream available: ${inputStream != null}")
                        Log.d(TAG, "L2CAP output stream available: ${outputStream != null}")
                        
                        // Try to get maximum transmission unit if available via reflection
                        try {
                            val mtuMethod = socket.javaClass.getMethod("getMaxTransmissionUnit")
                            val mtu = mtuMethod.invoke(socket) as? Int
                            Log.d(TAG, "L2CAP MTU: $mtu")
                        } catch (e: Exception) {
                            Log.d(TAG, "Could not get L2CAP MTU via reflection: ${e.message}")
                        }
                    } catch (e: Exception) {
                        Log.d(TAG, "Error getting socket details: ${e.message}")
                    }
                }
                
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
            
            Log.d(TAG, "Starting L2CAP read loop with buffer size ${buffer.size}")
            
            try {
                while (isActive && l2capSocket?.isConnected == true) {
                    val bytesRead = inputStream?.read(buffer) ?: -1
                    
                    if (bytesRead > 0) {
                        Log.d(TAG, "Read $bytesRead bytes from L2CAP")
                        val message = String(buffer, 0, bytesRead, Charsets.UTF_8)
                        Log.d(TAG, "Received message: '$message'")
                        sendEvent("message", message)
                    } else if (bytesRead == -1) {
                        Log.d(TAG, "End of stream reached, exiting read loop")
                        break // End of stream
                    } else if (bytesRead == 0) {
                        Log.d(TAG, "Read 0 bytes, continuing...")
                    }
                }
            } catch (e: IOException) {
                Log.e(TAG, "Error reading from L2CAP", e)
                sendEvent("error", "Read error: ${e.message}")
            }
            
            Log.d(TAG, "L2CAP read loop terminated")
            
            withContext(Dispatchers.Main) {
                disconnect()
            }
        }
    }
    
    private suspend fun sendMessage(message: String): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val bytes = message.toByteArray(Charsets.UTF_8)
                Log.d(TAG, "Sending message: '$message' (${bytes.size} bytes)")
                outputStream?.write(bytes)
                outputStream?.flush()
                Log.d(TAG, "Message sent successfully")
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
                Log.d(TAG, "Sending ${data.size} bytes of data")
                
                // L2CAP should handle chunking, but let's be defensive
                // If data is larger than expected, log a warning
                if (data.size > 1024) {
                    Log.w(TAG, "WARNING: Attempting to send ${data.size} bytes, which exceeds typical L2CAP MTU")
                }
                
                // Add validation to prevent sending corrupted data
                if (data.size > 65535) {
                    Log.e(TAG, "ERROR: Data size ${data.size} is unreasonably large, rejecting")
                    sendEvent("error", "Data size ${data.size} exceeds maximum (65535 bytes)")
                    return@withContext false
                }
                
                outputStream?.write(data)
                outputStream?.flush()
                Log.d(TAG, "Bytes sent successfully")
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
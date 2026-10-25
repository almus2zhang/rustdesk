package com.carriez.flutter_hbb

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * AOA Accessory Proxy Server
 * Bridges raw USB bulk stream from UsbAccessory to a local TCP port (127.0.0.1:21118/configured)
 * allowing full RustDesk protocol communication without requiring ADB or USB debugging.
 */
class AoaProxyServer(
    private val usbManager: UsbManager,
    private val accessory: UsbAccessory
) {
    private val logTag = "AoaProxy"
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var inputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null
    private var isRunning = false
    private var serverSocket: ServerSocket? = null

    fun start(targetLocalPort: Int = 21118) {
        if (isRunning) return
        isRunning = true

        thread(name = "AoaProxyThread") {
            try {
                fileDescriptor = usbManager.openAccessory(accessory)
                if (fileDescriptor == null) {
                    Log.e(logTag, "Failed to open UsbAccessory file descriptor!")
                    return@thread
                }

                val fd = fileDescriptor!!.fileDescriptor
                inputStream = FileInputStream(fd)
                outputStream = FileOutputStream(fd)
                Log.i(logTag, "Successfully opened UsbAccessory streams")

                // Start local TCP server for Flutter client to connect
                serverSocket = ServerSocket(targetLocalPort)
                Log.i(logTag, "AOA local proxy server listening on port $targetLocalPort")

                while (isRunning) {
                    val clientSocket = serverSocket?.accept() ?: break
                    Log.i(logTag, "Local client connected to AOA proxy")

                    val clientIn = clientSocket.getInputStream()
                    val clientOut = clientSocket.getOutputStream()

                    // Forward USB -> TCP
                    thread(name = "AoaUsbToTcp") {
                        val buffer = ByteArray(16384)
                        try {
                            while (isRunning) {
                                val bytesRead = inputStream?.read(buffer) ?: -1
                                if (bytesRead > 0) {
                                    clientOut.write(buffer, 0, bytesRead)
                                    clientOut.flush()
                                } else if (bytesRead < 0) {
                                    break
                                }
                            }
                        } catch (e: Exception) {
                            Log.d(logTag, "UsbToTcp stream ended: ${e.message}")
                        }
                    }

                    // Forward TCP -> USB
                    thread(name = "AoaTcpToUsb") {
                        val buffer = ByteArray(16384)
                        try {
                            while (isRunning) {
                                val bytesRead = clientIn.read(buffer)
                                if (bytesRead > 0) {
                                    outputStream?.write(buffer, 0, bytesRead)
                                    outputStream?.flush()
                                } else if (bytesRead < 0) {
                                    break
                                }
                            }
                        } catch (e: Exception) {
                            Log.d(logTag, "TcpToUsb stream ended: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(logTag, "AoaProxyServer error: ${e.message}", e)
            } finally {
                stop()
            }
        }
    }

    fun stop() {
        isRunning = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // ignore
        }
        try {
            inputStream?.close()
        } catch (e: Exception) {
            // ignore
        }
        try {
            outputStream?.close()
        } catch (e: Exception) {
            // ignore
        }
        try {
            fileDescriptor?.close()
        } catch (e: Exception) {
            // ignore
        }
        Log.i(logTag, "AoaProxyServer stopped")
    }
}

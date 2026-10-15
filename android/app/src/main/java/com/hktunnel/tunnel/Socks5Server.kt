package com.hktunnel.tunnel

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/**
 * Loopback SOCKS5 endpoint consumed by the tun2socks core.
 *
 * Only CONNECT is served: SSH port forwarding is TCP-only, and domain names
 * are passed through so the server resolves them. The core answers DNS itself
 * through its mapped-DNS cache, which is why plain UDP can be refused safely.
 */
class Socks5Server(
    private val port: Int,
    private val open: (String, Int) -> Channel,
    private val log: (String) -> Unit
) {
    interface Channel {
        val input: InputStream
        val output: OutputStream
        fun close()
    }

    @Volatile
    private var running = false
    @Volatile
    private var ipv6HintShown = false
    private val throttledFailures = ConcurrentHashMap<String, Long>()
    private var serverSocket: ServerSocket? = null

    fun start() {
        val socket = ServerSocket()
        socket.reuseAddress = true
        // Bind IPv4 loopback explicitly: getLoopbackAddress() hands back ::1 on
        // Android, while the tun2socks core always dials 127.0.0.1.
        socket.bind(InetSocketAddress(InetAddress.getByName(BIND_ADDRESS), port), BACKLOG)
        serverSocket = socket
        running = true
        Thread({ acceptLoop(socket) }, "socks5-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        serverSocket = null
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (running) {
            val client = try {
                socket.accept()
            } catch (_: IOException) {
                break
            }
            Thread({ serve(client) }, "socks5-conn").apply {
                isDaemon = true
                start()
            }
        }
    }

    private fun serve(client: Socket) {
        try {
            client.tcpNoDelay = true
            val input = client.getInputStream()
            val output = client.getOutputStream()

            val greeting = ByteArray(2)
            if (!readFully(input, greeting) || greeting[0].toInt() != SOCKS5) return
            val methods = ByteArray(greeting[1].toInt() and 0xFF)
            if (methods.isNotEmpty() && !readFully(input, methods)) return
            output.write(byteArrayOf(SOCKS5.toByte(), 0x00))
            output.flush()

            val head = ByteArray(4)
            if (!readFully(input, head) || head[0].toInt() != SOCKS5) return
            val command = head[1].toInt() and 0xFF
            val target = readTarget(input, head[3].toInt() and 0xFF) ?: return
            val portBytes = ByteArray(2)
            if (!readFully(input, portBytes)) return
            val targetPort = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)

            if (command != CMD_CONNECT) {
                reply(output, REP_COMMAND_UNSUPPORTED)
                return
            }

            val channel = try {
                open(target, targetPort)
            } catch (e: Exception) {
                reportFailure(target, targetPort, e)
                reply(output, REP_FAILURE)
                return
            }

            reply(output, REP_SUCCESS)
            relay(input, output, channel)
        } catch (_: Exception) {
        } finally {
            try {
                client.close()
            } catch (_: IOException) {
            }
        }
    }

    private fun relay(clientIn: InputStream, clientOut: OutputStream, channel: Channel) {
        val upload = Thread({
            try {
                copy(clientIn, channel.output)
            } catch (_: Exception) {
            } finally {
                channel.close()
            }
        }, "socks5-up")
        upload.isDaemon = true
        upload.start()

        try {
            copy(channel.input, clientOut)
        } catch (_: Exception) {
        } finally {
            channel.close()
        }
    }

    private fun copy(source: InputStream, sink: OutputStream) {
        val buffer = ByteArray(BUFFER_SIZE)
        while (true) {
            val read = source.read(buffer)
            if (read <= 0) return
            sink.write(buffer, 0, read)
            sink.flush()
        }
    }

    private fun readTarget(input: InputStream, addressType: Int): String? {
        return when (addressType) {
            ATYP_IPV4 -> {
                val bytes = ByteArray(4)
                if (!readFully(input, bytes)) return null
                InetAddress.getByAddress(bytes).hostAddress
            }
            ATYP_IPV6 -> {
                val bytes = ByteArray(16)
                if (!readFully(input, bytes)) return null
                InetAddress.getByAddress(bytes).hostAddress
            }
            ATYP_DOMAIN -> {
                val length = input.read()
                if (length <= 0) return null
                val bytes = ByteArray(length)
                if (!readFully(input, bytes)) return null
                String(bytes, Charsets.US_ASCII)
            }
            else -> null
        }
    }

    private fun reply(output: OutputStream, code: Int) {
        try {
            output.write(byteArrayOf(SOCKS5.toByte(), code.toByte(), 0, ATYP_IPV4.toByte(), 0, 0, 0, 0, 0, 0))
            output.flush()
        } catch (_: IOException) {
        }
    }

    /**
     * SSH forwarding here reaches IPv4 only: the server has no IPv6 egress, so
     * a channel to an IPv6 address always fails and apps fall back to IPv4 by
     * themselves. They retry often enough that reporting every attempt would
     * bury the log, so repeats against the same target are throttled.
     */
    private fun reportFailure(target: String, port: Int, error: Exception) {
        val reason = error.message ?: error.javaClass.simpleName

        if (target.contains(':')) {
            if (!ipv6HintShown) {
                ipv6HintShown = true
                log("服务器没有 IPv6 出口，走 IPv6 的请求会失败并自动改走 IPv4，属正常现象。")
            }
            if (!shouldReport(target)) return
        }

        log("连接 $target:$port 失败：$reason")
    }

    private fun shouldReport(target: String): Boolean {
        val now = System.currentTimeMillis()
        val previous = throttledFailures.put(target, now)
        if (throttledFailures.size > THROTTLE_TABLE_LIMIT) throttledFailures.clear()
        return previous == null || now - previous >= THROTTLE_WINDOW_MS
    }

    private fun readFully(input: InputStream, buffer: ByteArray): Boolean {
        var offset = 0
        while (offset < buffer.size) {
            val read = input.read(buffer, offset, buffer.size - offset)
            if (read <= 0) return false
            offset += read
        }
        return true
    }

    private companion object {
        const val BIND_ADDRESS = "127.0.0.1"
        const val SOCKS5 = 5
        const val CMD_CONNECT = 1
        const val ATYP_IPV4 = 1
        const val ATYP_DOMAIN = 3
        const val ATYP_IPV6 = 4
        const val REP_SUCCESS = 0
        const val REP_FAILURE = 5
        const val REP_COMMAND_UNSUPPORTED = 7
        const val BACKLOG = 64
        const val BUFFER_SIZE = 32 * 1024
        const val THROTTLE_WINDOW_MS = 60_000L
        const val THROTTLE_TABLE_LIMIT = 256
    }
}

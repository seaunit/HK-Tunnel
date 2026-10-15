package com.hktunnel.tunnel

import com.jcraft.jsch.Channel
import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * One SSH connection used as an on-demand pool of `direct-tcpip` channels.
 * Host names are handed to the server untouched, so name resolution happens
 * on the far side and never leaks to the local network.
 */
class SshTunnel(
    private val host: String,
    private val sshPort: Int,
    private val user: String,
    private val password: String,
    private val knownHostsPath: String
) {
    private var session: Session? = null

    fun connect(timeoutMs: Int = CONNECT_TIMEOUT_MS) {
        val knownHosts = File(knownHostsPath)
        knownHosts.parentFile?.mkdirs()
        val alreadyTrusted = isTrusted(knownHosts)

        val jsch = JSch()
        jsch.setKnownHosts(knownHostsPath)

        val opened = jsch.getSession(user, host, sshPort)
        opened.setPassword(password)
        opened.setConfig("PreferredAuthentications", "password,keyboard-interactive")
        // First contact trusts and pins; afterwards a changed key is refused.
        opened.setConfig("StrictHostKeyChecking", if (alreadyTrusted) "yes" else "no")
        opened.setServerAliveInterval(30_000)
        opened.setServerAliveCountMax(3)
        opened.timeout = timeoutMs
        opened.connect(timeoutMs)
        session = opened

        if (!alreadyTrusted) pinHostKey(opened)
    }

    fun open(host: String, port: Int): Socks5Server.Channel {
        val current = session ?: throw IllegalStateException("SSH 会话尚未建立")
        val channel = current.openChannel("direct-tcpip") as ChannelDirectTCPIP
        // Explicit setters: the same-named fields are package-private in JSch.
        channel.setHost(host)
        channel.setPort(port)
        channel.setOrgIPAddress("127.0.0.1")
        channel.setOrgPort(0)
        channel.connect(CONNECT_TIMEOUT_MS)
        return ChannelStreams(channel)
    }

    fun close() {
        try {
            session?.disconnect()
        } catch (_: Exception) {
        }
        session = null
    }

    private fun isTrusted(knownHosts: File): Boolean {
        if (!knownHosts.exists()) return false
        val entry = if (sshPort == 22) host else "[$host]:$sshPort"
        return try {
            knownHosts.useLines { lines ->
                lines.any { line ->
                    !line.startsWith("#") && line.substringBefore(' ').split(',').any { it == entry }
                }
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun pinHostKey(opened: Session) {
        try {
            val key = opened.hostKey ?: return
            val entry = if (sshPort == 22) host else "[$host]:$sshPort"
            // HostKey.getKey() already hands back the base64 key blob.
            File(knownHostsPath).appendText("$entry ${key.type} ${key.key}\n")
        } catch (_: Exception) {
        }
    }

    private class ChannelStreams(private val channel: Channel) : Socks5Server.Channel {
        // JSch hands out a fresh stream object per call, so both are cached.
        private val inbound: InputStream = channel.inputStream
        private val outbound: OutputStream = channel.outputStream

        override val input: InputStream get() = inbound
        override val output: OutputStream get() = outbound

        override fun close() {
            try {
                channel.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 20_000
    }
}

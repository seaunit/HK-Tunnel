package com.hktunnel.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import hev.htproxy.TProxyService
import java.io.File
import java.io.IOException

/**
 * Owns the whole tunnel: the SSH session, the loopback SOCKS5 endpoint and the
 * tun2socks core that turns the VpnService descriptor into SOCKS5 traffic.
 */
class TunnelVpnService : VpnService() {

    private var tunnel: SshTunnel? = null
    private var socks: Socks5Server? = null
    private var vpnInterface: ParcelFileDescriptor? = null
    private var coreRunning = false
    private var healthThread: Thread? = null

    /** True from the moment a start is accepted until teardown finishes. */
    @Volatile
    private var engaged = false

    /**
     * Teardown runs from several places (the stop action, onRevoke, onDestroy
     * and the health monitor). Only the first one should act, so a later
     * onDestroy cannot wipe out the final state the first one reported.
     */
    @Volatile
    private var stopped = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Thread({
                shutdown()
                TunnelBus.setState(TunnelState.Idle)
            }, "tunnel-stop").start()
            return START_NOT_STICKY
        }

        // A foreground service must post its notification immediately, even if
        // the settings turn out to be unusable.
        startForeground(NOTIFICATION_ID, buildNotification(getString(R.string.state_working)))
        if (engaged) return START_NOT_STICKY

        val stored = ProxyStore.load(this)
        val password = ProxyStore.consumeHandedOffPassword()
        if (stored == null || stored.host.isBlank()) {
            abort(getString(R.string.error_host_required))
            return START_NOT_STICKY
        }
        if (password.isEmpty()) {
            abort(getString(R.string.error_password_required))
            return START_NOT_STICKY
        }

        engaged = true
        TunnelBus.setState(TunnelState.Working)
        Thread({ launch(stored.copy(password = password)) }, "tunnel-start").start()
        return START_NOT_STICKY
    }

    private fun abort(message: String) {
        TunnelBus.log(message)
        TunnelBus.setState(TunnelState.Failed(message))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        TunnelBus.log("系统撤销了 VPN 授权，正在断开。")
        Thread({
            shutdown()
            TunnelBus.setState(TunnelState.Idle)
        }, "tunnel-revoke").start()
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun launch(config: ProxyConfig) {
        stopped = false
        try {
            TunnelBus.log("正在建立 SSH 连接 ${config.user}@${config.host}:${config.sshPort} …")
            val ssh = SshTunnel(
                host = config.host,
                sshPort = config.sshPort,
                user = config.user,
                password = config.password,
                knownHostsPath = File(filesDir, "known_hosts").absolutePath
            )
            ssh.connect()
            tunnel = ssh
            TunnelBus.log("SSH 已连接，主机密钥已校验。")

            val server = Socks5Server(config.socksPort, ssh::open, TunnelBus::log)
            server.start()
            socks = server
            TunnelBus.log("本地 SOCKS5 已监听 127.0.0.1:${config.socksPort}")

            val descriptor = establishInterface() ?: throw IOException("系统拒绝了 VPN 接口。")
            vpnInterface = descriptor

            if (!TProxyService.TProxyStartService(writeCoreConfig(config.socksPort), descriptor.fd)) {
                throw IOException("代理核心启动失败，请查看日志。")
            }
            coreRunning = true

            running = true
            TunnelBus.setState(TunnelState.Connected(config.host, config.socksPort))
            TunnelBus.log("全局代理已接管，全部流量经 ${config.host} 出口。")
            updateNotification(getString(R.string.state_connected))
            startHealthMonitor(ssh)
        } catch (e: Exception) {
            val message = e.message ?: e.javaClass.simpleName
            TunnelBus.log("启动失败：$message")
            shutdown()
            TunnelBus.setState(TunnelState.Failed(message))
        }
    }

    private fun establishInterface(): ParcelFileDescriptor? {
        val builder = Builder()
            .setSession(SESSION_NAME)
            .addAddress(TUNNEL_IPV4, IPV4_PREFIX)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(MAPPED_DNS)
            .setMtu(MTU)
            .setBlocking(false)
            // IPv6 is deliberately kept out of this VPN. The server has no IPv6
            // egress, so tunnelling it could only ever fail; allowFamily leaves
            // the family unblocked so its traffic falls through to the mobile
            // network instead. Dropping the address and route alone would block
            // IPv6 outright rather than let it bypass.
            .allowFamily(OsConstants.AF_INET6)

        // Keeps our own SSH socket out of the tunnel; without this it loops.
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }

        return builder.establish()
    }

    private fun writeCoreConfig(socksPort: Int): String {
        val target = File(filesDir, "hev-socks5-tunnel.yml")
        val logFile = File(filesDir, "hev-socks5-tunnel.log").absolutePath
        val yaml = buildString {
            appendLine("tunnel:")
            appendLine("  mtu: $MTU")
            appendLine("  ipv4: $TUNNEL_IPV4")
            appendLine("  icmp: 'off'")
            appendLine()
            appendLine("socks5:")
            appendLine("  port: $socksPort")
            appendLine("  address: 127.0.0.1")
            appendLine("  udp: 'udp'")
            appendLine()
            appendLine("mapdns:")
            appendLine("  address: $MAPPED_DNS")
            appendLine("  port: 53")
            appendLine("  network: $MAPPED_NETWORK")
            appendLine("  netmask: $MAPPED_NETMASK")
            // Without a cache size the mapped-DNS resolver stays switched off,
            // and name lookups would fall through to the (TCP-only) SOCKS5 path.
            appendLine("  cache-size: $MAPPED_DNS_CACHE")
            appendLine()
            appendLine("misc:")
            appendLine("  log-file: '$logFile'")
            appendLine("  log-level: info")
        }
        target.writeText(yaml)
        return target.absolutePath
    }

    private fun shutdown() {
        if (stopped) return
        stopped = true

        if (coreRunning) {
            coreRunning = false
            try {
                TProxyService.TProxyStopService()
            } catch (_: Throwable) {
            }
        }
        healthThread?.interrupt()
        healthThread = null
        socks?.stop()
        socks = null
        tunnel?.close()
        tunnel = null
        try {
            vpnInterface?.close()
        } catch (_: IOException) {
        }
        vpnInterface = null

        running = false
        engaged = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    /**
     * A VPN that outlives its SSH session is worse than no tunnel at all: every
     * connection on the device is captured and then fails, while the app still
     * claims to be connected. Watch the session and pull the VPN down as soon as
     * it is gone, so the phone falls back to its own network.
     */
    private fun startHealthMonitor(ssh: SshTunnel) {
        healthThread = Thread({
            while (running) {
                try {
                    Thread.sleep(HEALTH_CHECK_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (!running) return@Thread

                if (!ssh.isConnected()) {
                    TunnelBus.log("SSH 连接已断开，正在撤下 VPN 以免整机断网。")
                    shutdown()
                    TunnelBus.setState(TunnelState.Failed(getString(R.string.error_connection_lost)))
                    notifyConnectionLost()
                    return@Thread
                }
            }
        }, "tunnel-health")
        healthThread?.isDaemon = true
        healthThread?.start()
    }

    private fun notifyConnectionLost() {
        try {
            val open = PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            getSystemService(NotificationManager::class.java).notify(
                DISCONNECT_NOTIFICATION_ID,
                Notification.Builder(this, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_shield)
                    .setContentTitle(getString(R.string.app_name))
                    .setContentText(getString(R.string.error_connection_lost))
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .build()
            )
        } catch (_: Exception) {
        }
    }

    private fun buildNotification(text: String): Notification {
        ensureChannel()
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, TunnelVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_shield)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.notification_action_disconnect),
                    stop
                ).build()
            )
            .build()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.notification_channel),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    companion object {
        const val ACTION_START = "com.hktunnel.tunnel.action.START"
        const val ACTION_STOP = "com.hktunnel.tunnel.action.STOP"

        @Volatile
        var running: Boolean = false
            private set

        private const val CHANNEL_ID = "hktunnel-tunnel"
        private const val NOTIFICATION_ID = 1
        private const val DISCONNECT_NOTIFICATION_ID = 2
        private const val HEALTH_CHECK_INTERVAL_MS = 5_000L
        private const val SESSION_NAME = "HK-Tunnel"

        private const val TUNNEL_IPV4 = "198.18.0.1"
        private const val IPV4_PREFIX = 30
        private const val MAPPED_DNS = "198.18.0.2"
        private const val MAPPED_NETWORK = "100.64.0.0"
        private const val MAPPED_NETMASK = "255.192.0.0"
        private const val MAPPED_DNS_CACHE = 10000
        private const val MTU = 1500
    }
}

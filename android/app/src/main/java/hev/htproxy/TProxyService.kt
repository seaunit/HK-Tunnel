package hev.htproxy

/**
 * Thin binding for the vendored hev-socks5-tunnel native library.
 *
 * The package and class names are not free choices: the library's JNI_OnLoad
 * looks up exactly `hev/htproxy/TProxyService` and registers the four methods
 * below against it, so this file has to keep that identity.
 */
@Suppress("FunctionName", "unused")
object TProxyService {

    init {
        System.loadLibrary("hev-socks5-tunnel")
    }

    /** Starts the tunnel; [fd] is the tun descriptor taken from VpnService. */
    external fun TProxyStartService(configPath: String, fd: Int): Boolean

    external fun TProxyStopService(): Boolean

    external fun TProxyIsRunning(): Boolean

    /** Returns `[txPackets, txBytes, rxPackets, rxBytes]`. */
    external fun TProxyGetStats(): LongArray
}

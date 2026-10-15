package com.hktunnel.tunnel

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

sealed interface TunnelState {
    data object Idle : TunnelState
    data object Working : TunnelState
    data class Connected(val host: String, val socksPort: Int) : TunnelState
    data class Failed(val message: String) : TunnelState
}

/**
 * In-process bridge between the VPN service and whatever UI is on screen.
 * Both live in the same process, so plain flows are enough.
 */
object TunnelBus {

    private val _state = MutableStateFlow<TunnelState>(TunnelState.Idle)
    val state = _state.asStateFlow()

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log = _log.asStateFlow()

    fun setState(value: TunnelState) {
        _state.value = value
    }

    fun log(message: String) {
        val stamp = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        _log.value = (_log.value + "[$stamp] $message").takeLast(FAILED_LOG_LIMIT)
    }

    private const val FAILED_LOG_LIMIT = 200
}

package com.hktunnel.tunnel

data class ProxyConfig(
    val host: String,
    val sshPort: Int,
    val user: String,
    val password: String,
    val socksPort: Int,
    val remember: Boolean
)

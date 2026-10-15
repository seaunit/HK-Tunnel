package com.hktunnel.tunnel

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.hktunnel.tunnel.databinding.ActivityMainBinding
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    private val vpnConsent =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                launchTunnel()
            } else {
                ProxyStore.clearHandedOffPassword()
                toast(getString(R.string.error_vpn_denied))
            }
        }

    private val notificationConsent =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        bindSavedConfig()

        if (TunnelBus.log.value.isEmpty()) {
            TunnelBus.log("HK-Tunnel ${BuildConfig.VERSION_NAME} · ${BuildConfig.BUILD_STAMP}")
        }

        binding.buttonConnect.setOnClickListener { requestConnect() }
        binding.buttonDisconnect.setOnClickListener { requestDisconnect() }

        askForNotificationPermission()
        observeTunnel()
    }

    private fun bindSavedConfig() {
        val saved = ProxyStore.load(this) ?: return
        binding.inputHost.setText(saved.host)
        binding.inputSshPort.setText(saved.sshPort.toString())
        binding.inputUser.setText(saved.user)
        binding.inputSocksPort.setText(saved.socksPort.toString())
        binding.switchRemember.isChecked = saved.remember
        if (saved.remember && saved.password.isNotEmpty()) {
            binding.inputPassword.setText(saved.password)
        }
    }

    private fun requestConnect() {
        val config = readForm() ?: return
        ProxyStore.save(this, config)
        ProxyStore.handOffPassword(config.password)

        val consent = VpnService.prepare(this)
        if (consent != null) {
            vpnConsent.launch(consent)
        } else {
            launchTunnel()
        }
    }

    private fun requestDisconnect() {
        if (!TunnelVpnService.running) {
            TunnelBus.setState(TunnelState.Idle)
            return
        }
        startService(
            Intent(this, TunnelVpnService::class.java).setAction(TunnelVpnService.ACTION_STOP)
        )
    }

    private fun launchTunnel() {
        ContextCompat.startForegroundService(
            this,
            Intent(this, TunnelVpnService::class.java).setAction(TunnelVpnService.ACTION_START)
        )
    }

    private fun readForm(): ProxyConfig? {
        val host = binding.inputHost.text?.toString()?.trim().orEmpty()
        if (host.isEmpty()) {
            toast(getString(R.string.error_host_required))
            return null
        }

        val user = binding.inputUser.text?.toString()?.trim().orEmpty()
        if (user.isEmpty()) {
            toast(getString(R.string.error_user_required))
            return null
        }

        val password = binding.inputPassword.text?.toString().orEmpty()
        if (password.isEmpty()) {
            toast(getString(R.string.error_password_required))
            return null
        }

        val sshPort = binding.inputSshPort.text?.toString()?.trim()?.toIntOrNull()
        val socksPort = binding.inputSocksPort.text?.toString()?.trim()?.toIntOrNull()
        if (sshPort == null || sshPort !in 1..65535 || socksPort == null || socksPort !in 1024..65535) {
            toast(getString(R.string.error_bad_port))
            return null
        }

        return ProxyConfig(
            host = host,
            sshPort = sshPort,
            user = user,
            password = password,
            socksPort = socksPort,
            remember = binding.switchRemember.isChecked
        )
    }

    private fun observeTunnel() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { TunnelBus.state.collect(::render) }
                launch { TunnelBus.log.collect { binding.logView.text = it.joinToString("\n") } }
            }
        }
    }

    private fun render(state: TunnelState) {
        when (state) {
            TunnelState.Idle -> {
                binding.statusTitle.setText(R.string.state_idle)
                binding.statusTitle.setTextColor(color(R.color.state_stopped))
                binding.statusDetail.text = ""
                setControls(busy = false, connected = false)
            }
            TunnelState.Working -> {
                binding.statusTitle.setText(R.string.state_working)
                binding.statusTitle.setTextColor(color(R.color.state_stopped))
                binding.statusDetail.text = ""
                setControls(busy = true, connected = false)
            }
            is TunnelState.Connected -> {
                binding.statusTitle.setText(R.string.state_connected)
                binding.statusTitle.setTextColor(color(R.color.state_running))
                binding.statusDetail.text =
                    getString(R.string.detail_connected, state.host, state.socksPort)
                setControls(busy = false, connected = true)
            }
            is TunnelState.Failed -> {
                binding.statusTitle.setText(R.string.state_failed)
                binding.statusTitle.setTextColor(color(R.color.state_failed))
                binding.statusDetail.text = state.message
                setControls(busy = false, connected = false)
            }
        }
    }

    private fun setControls(busy: Boolean, connected: Boolean) {
        binding.buttonConnect.isEnabled = !busy && !connected
        binding.buttonDisconnect.isEnabled = !busy && connected
        binding.inputHost.isEnabled = !busy && !connected
        binding.inputSshPort.isEnabled = !busy && !connected
        binding.inputUser.isEnabled = !busy && !connected
        binding.inputPassword.isEnabled = !busy && !connected
        binding.inputSocksPort.isEnabled = !busy && !connected
        binding.switchRemember.isEnabled = !busy && !connected
    }

    private fun askForNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) notificationConsent.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun color(resource: Int) = ContextCompat.getColor(this, resource)

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
}

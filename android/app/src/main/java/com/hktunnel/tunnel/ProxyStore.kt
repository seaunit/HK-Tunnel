package com.hktunnel.tunnel

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Connection settings, with the password sealed by a hardware-backed
 * AndroidKeyStore key so the plaintext never lands in SharedPreferences.
 */
object ProxyStore {

    /**
     * The password only reaches disk when "remember" is on. Until then the
     * activity hands it to the service in memory: both live in the same
     * process, so it never has to travel through an Intent.
     */
    @Volatile
    private var handedOffPassword: String = ""

    fun handOffPassword(password: String) {
        handedOffPassword = password
    }

    fun consumeHandedOffPassword(): String {
        val password = handedOffPassword
        handedOffPassword = ""
        return password
    }

    fun clearHandedOffPassword() {
        handedOffPassword = ""
    }

    private const val PREFS = "hktunnel"
    private const val KEY_ALIAS = "hktunnel-password"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128

    private const val KEY_HOST = "host"
    private const val KEY_SSH_PORT = "sshPort"
    private const val KEY_USER = "user"
    private const val KEY_SOCKS_PORT = "socksPort"
    private const val KEY_REMEMBER = "remember"
    private const val KEY_PASSWORD = "password"

    fun load(context: Context): ProxyConfig? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val host = prefs.getString(KEY_HOST, null) ?: return null
        if (host.isBlank()) return null

        val remember = prefs.getBoolean(KEY_REMEMBER, false)
        return ProxyConfig(
            host = host,
            sshPort = prefs.getInt(KEY_SSH_PORT, 22),
            user = prefs.getString(KEY_USER, "root") ?: "root",
            password = if (remember) decrypt(prefs.getString(KEY_PASSWORD, null)) else "",
            socksPort = prefs.getInt(KEY_SOCKS_PORT, 1080),
            remember = remember
        )
    }

    fun save(context: Context, config: ProxyConfig) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_HOST, config.host)
            .putInt(KEY_SSH_PORT, config.sshPort)
            .putString(KEY_USER, config.user)
            .putInt(KEY_SOCKS_PORT, config.socksPort)
            .putBoolean(KEY_REMEMBER, config.remember)

        if (config.remember && config.password.isNotEmpty()) {
            editor.putString(KEY_PASSWORD, encrypt(config.password))
        } else {
            editor.remove(KEY_PASSWORD)
        }
        editor.apply()
    }

    private fun encrypt(plain: String): String? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val payload = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(payload, Base64.NO_WRAP)
    } catch (_: Exception) {
        null
    }

    private fun decrypt(stored: String?): String {
        if (stored.isNullOrEmpty()) return ""
        return try {
            val parts = stored.split(':')
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(TAG_BITS, Base64.decode(parts[0], Base64.NO_WRAP))
            )
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) {
            ""
        }
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }
}

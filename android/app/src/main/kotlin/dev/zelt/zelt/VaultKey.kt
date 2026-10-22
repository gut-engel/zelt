package dev.zelt.zelt

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The vault's hardware key: AES-256-GCM in the Android Keystore, never
 * exportable. StrongBox when the phone has it, otherwise the TEE. The Dart
 * vault wraps its PIN-protected master key with it, so a copied vault can
 * only be attacked on this device.
 */
object VaultKey {
    private const val ALIAS = "zelt_vault_v2"
    private const val TAG_BITS = 128
    private var strongBox: Boolean? = null

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun key(): SecretKey {
        val ks = keyStore()
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        fun spec(sb: Boolean) = KeyGenParameterSpec.Builder(
            ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .apply { if (sb && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
            .build()
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        return try {
            gen.init(spec(true))
            gen.generateKey().also { strongBox = Build.VERSION.SDK_INT >= 28 }
        } catch (e: StrongBoxUnavailableException) {
            gen.init(spec(false))
            gen.generateKey().also { strongBox = false }
        }
    }

    /** "strongbox" or "tee". */
    fun info(): String {
        key()
        if (strongBox == null) {
            // Key existed already: ask the keystore where it lives.
            strongBox = try {
                val k = key()
                val factory = javax.crypto.SecretKeyFactory.getInstance(k.algorithm, "AndroidKeyStore")
                val ki = factory.getKeySpec(k, android.security.keystore.KeyInfo::class.java)
                    as android.security.keystore.KeyInfo
                if (Build.VERSION.SDK_INT >= 31) {
                    ki.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
                } else false
            } catch (e: Exception) {
                false
            }
        }
        return if (strongBox == true) "strongbox" else "tee"
    }

    /** iv(12) || ciphertext+tag. */
    fun wrap(data: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(data)
    }

    fun unwrap(data: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, data.copyOfRange(0, 12)))
        return c.doFinal(data.copyOfRange(12, data.size))
    }
}

package dev.onecursor.protocol

import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** Certificate fingerprints in the colon separated upper-case hex form Barrier displays. */
data class CertFingerprint(val sha256: String, val sha1: String) {
    companion object {
        fun of(cert: X509Certificate): CertFingerprint = of(cert.encoded)

        fun of(der: ByteArray) = CertFingerprint(
            sha256 = hex(MessageDigest.getInstance("SHA-256").digest(der)),
            sha1 = hex(MessageDigest.getInstance("SHA-1").digest(der)),
        )

        fun hex(bytes: ByteArray) = bytes.joinToString(":") { "%02X".format(it.toInt() and 0xff) }

        /** Normalises user input such as "aa:bb..." or "AABB..." for comparisons. */
        fun normalize(s: String) = s.filter { it.isLetterOrDigit() }.uppercase()
    }
}

/**
 * Decides whether a server certificate is trusted. Barrier servers use
 * self-signed certificates, so trust is established by pinning fingerprints
 * (trust on first use is up to the implementation).
 */
fun interface ServerTrust {
    fun isTrusted(host: String, fingerprint: CertFingerprint): Boolean
}

class UntrustedServerException(val host: String, val fingerprint: CertFingerprint) :
    Exception("server certificate is not trusted (SHA-256 ${fingerprint.sha256})")

internal object Tls {
    /**
     * Wraps [plain] in TLS. Certificate chains are not validated against a CA;
     * instead the leaf certificate's fingerprint is checked with [trust].
     */
    fun wrap(plain: Socket, host: String, port: Int, trust: ServerTrust): SSLSocket {
        var rejected: CertFingerprint? = null
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
                throw CertificateException("client mode only")

            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val leaf = chain?.firstOrNull() ?: throw CertificateException("no server certificate")
                val fp = CertFingerprint.of(leaf)
                if (!trust.isTrusted(host, fp)) {
                    rejected = fp
                    throw CertificateException("untrusted server certificate ${fp.sha256}")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(null, arrayOf(tm), SecureRandom())
        val ssl = ctx.socketFactory.createSocket(plain, host, port, true) as SSLSocket
        ssl.useClientMode = true
        try {
            ssl.startHandshake()
        } catch (e: Exception) {
            rejected?.let { throw UntrustedServerException(host, it) }
            throw e
        }
        return ssl
    }
}

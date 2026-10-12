package dev.onecursor.android

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class DiscoveredServer(val name: String, val host: String, val port: Int, val tls: Boolean)

/**
 * Finds One Cursor servers on the local network. The macOS server advertises
 * `_onecursor._tcp` over Bonjour with a `tls` TXT record. (Plain Barrier
 * servers do not advertise themselves; enter their address by hand.)
 */
class ServerDiscovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())
    private val _servers = MutableStateFlow<List<DiscoveredServer>>(emptyList())
    val servers: StateFlow<List<DiscoveredServer>> = _servers.asStateFlow()

    private var listener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    // NsdManager resolves one service at a time on older Android versions.
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (listener != null) return
        multicastLock = wifi.createMulticastLock("one-cursor-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                main.post {
                    resolveQueue.addLast(info)
                    resolveNext()
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                main.post { _servers.value = _servers.value.filterNot { it.name == info.serviceName } }
            }
        }
        listener = l
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
            .onFailure { listener = null }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        multicastLock?.let { runCatching { it.release() } }
        multicastLock = null
        resolveQueue.clear()
    }

    private fun resolveNext() {
        if (resolving) return
        val info = resolveQueue.removeFirstOrNull() ?: return
        resolving = true
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post {
                    resolving = false
                    resolveNext()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val host = serviceInfo.host?.hostAddress
                val tls = serviceInfo.attributes["tls"]?.let { String(it) } != "0"
                main.post {
                    resolving = false
                    if (host != null) {
                        val server = DiscoveredServer(serviceInfo.serviceName, host, serviceInfo.port, tls)
                        _servers.value = _servers.value.filterNot { it.name == server.name } + server
                    }
                    resolveNext()
                }
            }
        })
    }

    companion object {
        const val SERVICE_TYPE = "_onecursor._tcp."
    }
}

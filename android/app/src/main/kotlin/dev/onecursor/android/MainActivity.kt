package dev.onecursor.android

import android.content.Intent
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private lateinit var discovery: ServerDiscovery

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        discovery = ServerDiscovery(this)
        val app = OneCursorApp.of(this)
        setContent {
            OneCursorTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    MainScreen(app, discovery, onSendClipboard = ::sendClipboardNow)
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        discovery.start()
    }

    override fun onStop() {
        discovery.stop()
        super.onStop()
    }

    private fun sendClipboardNow() {
        val text = ClipboardSyncActivity.readClipboard(this)
        val sent = text != null && OneCursorApp.of(this).controller.sendClipboard(text)
        Toast.makeText(this, if (sent) R.string.share_sent else R.string.share_not_connected, Toast.LENGTH_SHORT).show()
    }
}

@Composable
private fun OneCursorTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) {
        darkColorScheme(primary = Color(0xFF9AAEFF), secondary = Color(0xFF7FD3B6))
    } else {
        lightColorScheme(primary = Color(0xFF3355DD), secondary = Color(0xFF1B8A68))
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
private fun MainScreen(app: OneCursorApp, discovery: ServerDiscovery, onSendClipboard: () -> Unit) {
    val context = LocalContext.current
    val settings = app.settings
    val controller = app.controller
    val state by controller.state.collectAsStateWithLifecycle()
    val servers by discovery.servers.collectAsStateWithLifecycle()

    var host by remember { mutableStateOf(settings.host) }
    var port by remember { mutableStateOf(settings.port.toString()) }
    var name by remember { mutableStateOf(settings.screenName) }
    var tls by remember { mutableStateOf(settings.useTls) }

    fun saveConnectionFields() {
        settings.host = host
        port.toIntOrNull()?.takeIf { it in 1..65535 }?.let { settings.port = it }
        if (name.isNotBlank()) settings.screenName = name
        settings.useTls = tls
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)

        if (!state.serviceRunning) {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.service_off_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.service_off_body), style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = {
                        context.startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS))
                    }) { Text(stringResource(R.string.service_enable)) }
                }
            }
        }

        StatusCard(state)

        Section(R.string.section_connection) {
            OutlinedTextField(
                value = host, onValueChange = { host = it.trim() },
                label = { Text(stringResource(R.string.field_host)) },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = port, onValueChange = { v -> port = v.filter { it.isDigit() }.take(5) },
                    label = { Text(stringResource(R.string.field_port)) },
                    singleLine = true, modifier = Modifier.width(110.dp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                OutlinedTextField(
                    value = name, onValueChange = { name = it.trim() },
                    label = { Text(stringResource(R.string.field_name)) },
                    singleLine = true, modifier = Modifier.weight(1f),
                )
            }
            Text(stringResource(R.string.field_name_help), style = MaterialTheme.typography.bodySmall)
            SwitchRow(R.string.field_tls, tls, help = R.string.field_tls_help) { tls = it }

            val busy = state.status == UiState.Status.CONNECTED || state.status == UiState.Status.CONNECTING ||
                state.status == UiState.Status.RETRYING
            if (busy) {
                OutlinedButton(onClick = { controller.disconnect() }, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.disconnect))
                }
            } else {
                Button(
                    onClick = {
                        saveConnectionFields()
                        controller.connect()
                    },
                    enabled = host.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.connect)) }
            }

            HorizontalDivider()
            Text(stringResource(R.string.discovered), style = MaterialTheme.typography.titleSmall)
            if (servers.isEmpty()) {
                Text(stringResource(R.string.discovered_none), style = MaterialTheme.typography.bodySmall)
            }
            servers.forEach { s ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(MaterialTheme.shapes.small)
                        .clickable {
                            host = s.host
                            port = s.port.toString()
                            tls = s.tls
                            saveConnectionFields()
                            controller.connect()
                        }
                        .padding(vertical = 10.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(s.name, style = MaterialTheme.typography.bodyLarge)
                        Text("${s.host}:${s.port}", style = MaterialTheme.typography.bodySmall)
                    }
                    Text(stringResource(R.string.connect), color = MaterialTheme.colorScheme.primary)
                }
            }
        }

        InputSection(app)

        Section(R.string.section_clipboard) {
            Text(stringResource(R.string.clipboard_help), style = MaterialTheme.typography.bodyMedium)
            var sync by remember { mutableStateOf(settings.syncClipboardOnLeave) }
            SwitchRow(R.string.sync_on_leave, sync, help = R.string.sync_on_leave_help) {
                sync = it
                settings.syncClipboardOnLeave = it
            }
            OutlinedButton(onClick = onSendClipboard, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.send_clipboard))
            }
            TextButton(onClick = { settings.forgetTrustedServers() }) { Text(stringResource(R.string.forget_servers)) }
        }

        Section(R.string.help_title) {
            Text(stringResource(R.string.help_body), style = MaterialTheme.typography.bodyMedium)
        }
        Spacer(Modifier.size(24.dp))
    }

    state.pendingTrust?.let { pending ->
        AlertDialog(
            onDismissRequest = { controller.rejectPendingTrust() },
            title = { Text(stringResource(R.string.trust_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.trust_body, pending.host))
                    Text(
                        pending.fingerprint.sha256,
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            },
            confirmButton = { TextButton(onClick = { controller.acceptPendingTrust() }) { Text(stringResource(R.string.trust_accept)) } },
            dismissButton = { TextButton(onClick = { controller.rejectPendingTrust() }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun StatusCard(state: UiState) {
    val (label, color) = when (state.status) {
        UiState.Status.IDLE -> stringResource(R.string.status_idle) to MaterialTheme.colorScheme.outline
        UiState.Status.CONNECTING -> stringResource(R.string.status_connecting, state.server ?: "") to Color(0xFFE0A100)
        UiState.Status.CONNECTED -> stringResource(R.string.status_connected, state.server ?: "") to Color(0xFF2E9E5B)
        UiState.Status.RETRYING -> stringResource(R.string.status_retrying) to Color(0xFFE0A100)
        UiState.Status.ERROR -> stringResource(R.string.status_error) to MaterialTheme.colorScheme.error
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(color),
                )
                Spacer(Modifier.width(10.dp))
                Text(label, style = MaterialTheme.typography.titleMedium)
            }
            state.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            if (state.status == UiState.Status.CONNECTED) {
                Text(
                    stringResource(if (state.active) R.string.status_active else R.string.status_inactive),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

@Composable
private fun InputSection(app: OneCursorApp) {
    val settings = app.settings
    Section(R.string.section_input) {
        var pointer by remember { mutableFloatStateOf(settings.pointerSpeed) }
        Text(stringResource(R.string.pointer_speed, pointer))
        Slider(
            value = pointer, onValueChange = { pointer = (it * 4).toInt() / 4f }, valueRange = 0.5f..4f,
            onValueChangeFinished = {
                settings.pointerSpeed = pointer
                app.controller.screenChanged()
            },
        )
        var scroll by remember { mutableFloatStateOf(settings.scrollSpeed) }
        Text(stringResource(R.string.scroll_speed, scroll))
        Slider(
            value = scroll, onValueChange = { scroll = (it * 4).toInt() / 4f }, valueRange = 0.25f..4f,
            onValueChangeFinished = {
                settings.scrollSpeed = scroll
                CursorService.instance?.applySettings()
            },
        )
        var invert by remember { mutableStateOf(settings.invertScroll) }
        SwitchRow(R.string.invert_scroll, invert) {
            invert = it
            settings.invertScroll = it
            CursorService.instance?.applySettings()
        }
        var right by remember { mutableStateOf(settings.rightButton) }
        ActionPicker(R.string.right_button, right) {
            right = it
            settings.rightButton = it
        }
        var middle by remember { mutableStateOf(settings.middleButton) }
        ActionPicker(R.string.middle_button, middle) {
            middle = it
            settings.middleButton = it
        }
        var telex by remember { mutableStateOf(settings.vietnameseTelex) }
        SwitchRow(R.string.telex, telex, help = R.string.telex_help) {
            telex = it
            settings.vietnameseTelex = it
            CursorService.instance?.applySettings()
        }
    }
}

@Composable
private fun ActionPicker(@StringRes label: Int, value: ButtonAction, onChange: (ButtonAction) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { open = true }
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(label), modifier = Modifier.weight(1f))
        Box {
            Text(stringResource(actionLabel(value)), color = MaterialTheme.colorScheme.primary)
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                ButtonAction.entries.forEach { a ->
                    DropdownMenuItem(text = { Text(stringResource(actionLabel(a))) }, onClick = {
                        onChange(a)
                        open = false
                    })
                }
            }
        }
    }
}

@StringRes
private fun actionLabel(a: ButtonAction) = when (a) {
    ButtonAction.BACK -> R.string.action_back
    ButtonAction.HOME -> R.string.action_home
    ButtonAction.RECENTS -> R.string.action_recents
    ButtonAction.NOTIFICATIONS -> R.string.action_notifications
    ButtonAction.LONG_PRESS -> R.string.action_long_press
    ButtonAction.NONE -> R.string.action_none
}

@Composable
private fun SwitchRow(@StringRes label: Int, checked: Boolean, @StringRes help: Int? = null, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onChange(!checked) }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(label))
            help?.let { Text(stringResource(it), style = MaterialTheme.typography.bodySmall) }
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Section(@StringRes title: Int, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

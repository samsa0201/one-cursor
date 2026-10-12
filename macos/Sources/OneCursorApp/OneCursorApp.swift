import AppKit
import OneCursorCore
import OneCursorMac
import SwiftUI
import UniformTypeIdentifiers

@main
struct OneCursorMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.running ? "cursorarrow.rays" : "cursorarrow")
        }

        Window("One Cursor", id: "settings") {
            SettingsView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if model.mode == .server && model.running && !model.activeScreen.isEmpty {
            Text("Cursor on: \(model.activeScreen)")
        }
        Divider()
        Button(model.running ? "Stop" : "Start \(model.mode == .server ? "Server" : "Client")") {
            model.running ? model.stop() : model.start()
        }
        if model.mode == .server && model.running {
            Button("Bring Cursor Back") { model.returnCursor() }
                .keyboardShortcut(.escape, modifiers: [.control, .option, .command])
        }
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit One Cursor") {
            model.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            LayoutTab(model: model).tabItem { Label("Screens", systemImage: "rectangle.3.group") }
            PermissionsTab(model: model).tabItem { Label("Permissions", systemImage: "lock.shield") }
            LogTab(model: model).tabItem { Label("Log", systemImage: "text.alignleft") }
        }
        .padding()
        .sheet(item: Binding(get: { model.pendingFingerprint.map(IdentifiedString.init) },
                             set: { model.pendingFingerprint = $0?.value })) { fp in
            TrustSheet(model: model, fingerprint: fp.value)
        }
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("This Mac is a", selection: $model.mode) {
                    Text("Server (share this Mac's mouse & keyboard)").tag(Mode.server)
                    Text("Client (controlled by another computer)").tag(Mode.client)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.running)
                TextField("Screen name", text: $model.screenName)
                    .disabled(model.running)
                if model.mode == .client {
                    TextField("Server address", text: $model.serverHost, prompt: Text("192.168.1.10 or host:port"))
                        .disabled(model.running)
                }
                TextField("Port", value: $model.port, format: .number.grouping(.never))
                    .disabled(model.running)
                Toggle("Encrypt connections (TLS)", isOn: $model.useTLS)
                    .disabled(model.running)
                Toggle("Start when the app opens", isOn: $model.startAtLaunch)
            }

            if model.mode == .server, let fp = model.fingerprint, model.useTLS {
                Section("Certificate fingerprint (SHA-256)") {
                    Text(fp)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Clients show this fingerprint the first time they connect. Check that it matches before trusting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fp, forType: .string)
                    }
                }
            }

            Section {
                HStack {
                    Circle()
                        .fill(model.running ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(model.statusText)
                    Spacer()
                    Button(model.running ? "Stop" : "Start") {
                        model.running ? model.stop() : model.start()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if model.mode == .server {
                    ForEach(model.clients, id: \.name) { c in
                        HStack {
                            Image(systemName: c.name == model.activeScreen ? "cursorarrow.rays" : "display")
                            Text(c.name)
                            Spacer()
                            Text(c.address).foregroundStyle(.secondary)
                            if let s = c.shape { Text("\(Int(s.width))×\(Int(s.height))").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

struct LayoutTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if let custom = model.customConfig {
                Section("Imported Barrier configuration") {
                    Text("Screens: " + custom.screens.map(\.name).joined(separator: ", "))
                    Text(custom.barrierText())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Use the simple editor instead") { model.customConfig = nil }
                }
            } else {
                Section("Arrangement") {
                    LayoutPreview(serverName: model.screenName, placements: model.placements)
                        .frame(height: 170)
                    ForEach($model.placements) { $p in
                        HStack {
                            TextField("Screen name", text: $p.name)
                            Picker("", selection: $p.side) {
                                Text("Left of this Mac").tag(Direction.left)
                                Text("Right of this Mac").tag(Direction.right)
                                Text("Above this Mac").tag(Direction.top)
                                Text("Below this Mac").tag(Direction.bottom)
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Button(role: .destructive) {
                                model.placements.removeAll { $0.id == p.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Screen") {
                        let used = Set(model.placements.map(\.side))
                        let side = [Direction.right, .left, .top, .bottom].first { !used.contains($0) } ?? .right
                        model.placements.append(Placement(name: "", side: side))
                    }
                    Text("Use the same name as the screen name set on the phone or other computer (Android app, Barrier or Input Leap client).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Options") {
                Stepper("Switch delay: \(model.switchDelay) ms", value: $model.switchDelay, in: 0...1000, step: 50)
                Toggle("Share clipboard", isOn: $model.clipboardSharing)
            }

            Section("Barrier configuration file") {
                HStack {
                    Button("Import…") { importConfig() }
                    Button("Export…") { exportConfig() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importBarrierConfig(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "barrier.conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportBarrierConfig(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Draws this Mac in the middle and the other screens around it.
struct LayoutPreview: View {
    let serverName: String
    let placements: [Placement]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let box = CGSize(width: min(130, w / 4), height: min(80, h / 2.6))
            let center = CGPoint(x: w / 2, y: h / 2)
            ZStack {
                screenBox(serverName.isEmpty ? "This Mac" : serverName, systemImage: "laptopcomputer", highlighted: true)
                    .frame(width: box.width, height: box.height)
                    .position(center)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    ForEach(Array(group.1.enumerated()), id: \.element.id) { index, p in
                        screenBox(p.name.isEmpty ? "?" : p.name, systemImage: "iphone", highlighted: false)
                            .frame(width: box.width * 0.8, height: box.height * 0.8)
                            .position(position(for: group.0, index: index, count: group.1.count, center: center, box: box))
                    }
                }
            }
        }
    }

    private var groups: [(Direction, [Placement])] {
        [Direction.left, .right, .top, .bottom].map { d in (d, placements.filter { $0.side == d }) }.filter { !$0.1.isEmpty }
    }

    private func position(for side: Direction, index: Int, count: Int, center: CGPoint, box: CGSize) -> CGPoint {
        let spread = Double(index) - Double(count - 1) / 2
        switch side {
        case .left: return CGPoint(x: center.x - box.width * 1.05, y: center.y + spread * box.height * 0.85)
        case .right: return CGPoint(x: center.x + box.width * 1.05, y: center.y + spread * box.height * 0.85)
        case .top: return CGPoint(x: center.x + spread * box.width * 0.85, y: center.y - box.height * 0.95)
        case .bottom: return CGPoint(x: center.x + spread * box.width * 0.85, y: center.y + box.height * 0.95)
        }
    }

    private func screenBox(_ title: String, systemImage: String, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(highlighted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlighted ? Color.accentColor : Color.secondary, lineWidth: 1))
            .overlay(VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title).font(.caption).lineLimit(1)
            }.padding(4))
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                permissionRow("Accessibility", granted: model.accessibilityGranted,
                              detail: "Needed to capture and control the mouse and keyboard.") {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                permissionRow("Input Monitoring", granted: model.inputMonitoringGranted,
                              detail: "Needed to read keyboard input while sharing it.") {
                    Permissions.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
            } footer: {
                Text("After granting a permission, stop and start One Cursor again. If you rebuild the app, remove and re-add it in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: request) }
        }
    }
}

// MARK: - Log

struct LogTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: model.log.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - Trust

struct TrustSheet: View {
    @ObservedObject var model: AppModel
    let fingerprint: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trust this server?").font(.headline)
            Text("The server presented this certificate fingerprint (SHA-256). Compare it with the fingerprint shown on the server before trusting it.")
            Text(fingerprint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.pendingFingerprint = nil
                    model.stop()
                    dismiss()
                }
                Button("Trust") {
                    model.trustPendingFingerprint()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

import CoreBluetooth
import OralBKit
import SwiftUI

@main
struct LocalBrushApp: App {
    @StateObject private var manager = BrushManager()

    var body: some Scene {
        WindowGroup {
            ScanView().environmentObject(manager)
        }
    }
}

// MARK: - Scan (passive)

struct ScanView: View {
    @EnvironmentObject var manager: BrushManager

    var body: some View {
        NavigationStack {
            List {
                if manager.bluetoothState != .poweredOn {
                    Text(bluetoothMessage).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(manager.brushes.values.sorted { $0.rssi > $1.rssi }) { brush in
                        NavigationLink(value: brush.id) { BrushRow(brush: brush) }
                    }
                } header: {
                    Text("Nearby Oral-B brushes")
                } footer: {
                    Text("Press the brush's power button to wake it. Live data here comes from advertisements only: nothing is sent to the brush.")
                }
            }
            .navigationTitle("LocalBrush")
            .navigationDestination(for: UUID.self) { DeviceView(id: $0) }
            .toolbar { NavigationLink("History") { HistoryView() } }
        }
    }

    var bluetoothMessage: String {
        switch manager.bluetoothState {
        case .unauthorized: return "Bluetooth permission denied. Enable it in Settings › LocalBrush."
        case .poweredOff: return "Bluetooth is off."
        case .unsupported: return "Bluetooth LE is not supported on this device (the Simulator has no Bluetooth)."
        default: return "Waiting for Bluetooth…"
        }
    }
}

struct BrushRow: View {
    let brush: DiscoveredBrush

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(brush.name).font(.headline)
                Spacer()
                Text("\(brush.rssi) dBm").font(.caption).foregroundStyle(.secondary)
            }
            if let ad = brush.advertisement {
                Text(ad.modelName).font(.subheadline)
                Text("\(ad.stateName) · \(ad.modeName) · \(ad.timeText)").font(.caption)
            } else {
                Text("Unrecognized advertisement format").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Device dashboard

struct DeviceView: View {
    @EnvironmentObject var manager: BrushManager
    let id: UUID
    @State private var error: String?

    var brush: DiscoveredBrush? { manager.brushes[id] }
    var connected: Bool { manager.connectedID == id }

    var body: some View {
        List {
            if let ad = brush?.advertisement {
                Section("Live (from advertisements)") {
                    LabeledContent("State", value: ad.stateName)
                    LabeledContent("Mode", value: ad.modeName)
                    LabeledContent("Brushing time", value: ad.timeText)
                    LabeledContent("Pressure") {
                        Text(ad.pressure.rawValue).foregroundStyle(ad.pressure == .high ? .red : .primary)
                    }
                    LabeledContent("Sector", value: ad.sectorText)
                }
                Section("Identity") {
                    LabeledContent("Model type", value: "\(ad.modelType) – \(ad.modelName)")
                    LabeledContent("Protocol", value: "\(ad.protocolVersion)")
                    LabeledContent("Firmware byte", value: "\(ad.firmware)")
                    LabeledContent("Raw", value: ad.raw.hex).font(.caption.monospaced())
                }
            }

            Section("Connection") {
                LabeledContent("Status", value: manager.status)
                if connected {
                    if let b = manager.battery {
                        LabeledContent("Battery", value: "\(b.percent)%")
                    }
                    if let m = manager.model {
                        LabeledContent("Model (GATT)", value: m.name)
                    }
                    NavigationLink("Brushing modes") { ModesView() }
                    NavigationLink("Stored sessions") { DeviceSessionsView() }
                    NavigationLink("Inspector") { InspectorView() }
                    Button("Disconnect", role: .destructive) { manager.disconnect() }
                } else {
                    Button("Connect") { run { try await manager.connect(id) } }
                    Text("Close the Oral-B app first: the brush accepts one connection at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(brush?.name ?? "Brush")
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    func run(_ op: @escaping () async throws -> Void) {
        Task { do { try await op() } catch { self.error = error.localizedDescription } }
    }
}

// MARK: - Modes

struct ModesView: View {
    @EnvironmentObject var manager: BrushManager
    @State private var selection: [UInt8] = []
    @State private var message: String?
    @State private var confirming = false
    @State private var restoring = false

    var backup: Backup? { manager.connectedID.flatMap(BackupStore.load) }

    var body: some View {
        List {
            Section {
                if let modes = manager.availableModes {
                    ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                        LabeledContent("Slot \(i)", value: "\(OralB.modeName(m)) (\(m))")
                    }
                    LabeledContent("Raw", value: modes.hex).font(.caption.monospaced())
                } else {
                    Text("This handle did not return an available-modes value.")
                }
            } header: {
                Text("On the handle now")
            } footer: {
                Text("This list sets which modes the handle's mode button cycles through. It does not change motor speed, the pressure sensor or the timer.")
            }

            Section("1. Backup") {
                if let backup {
                    LabeledContent("Saved", value: backup.taken.formatted())
                    LabeledContent("Value", value: backup.availableModes.hex).font(.caption.monospaced())
                } else {
                    Button("Save backup of current value") { run { try await manager.saveBackup(); return "saved" } }
                }
            }

            if backup != nil, let current = manager.availableModes {
                Section {
                    ForEach(OralB.selectableModes, id: \.self) { m in
                        Button { toggle(m) } label: {
                            HStack {
                                Text(OralB.modeName(m)).foregroundStyle(.primary)
                                Spacer()
                                if let i = selection.firstIndex(of: m) { Text("#\(i + 1)").foregroundStyle(.tint) }
                            }
                        }
                    }
                    Button("Write \(selection.count) mode(s) to handle") { confirming = true }
                        .disabled(selection.isEmpty || (try? AvailableModes.encode(selection, current: current)) == nil)
                    Button("Restore backup", role: .destructive) { restoring = true }
                } header: {
                    Text("2. Choose modes (experimental, reversible)")
                } footer: {
                    Text("Tap in the order you want the mode button to cycle. Only modes this handle's hardware variant supports will run. If a mode doesn't appear on the handle afterwards, restore the backup.")
                }
                .onAppear { if selection.isEmpty { selection = AvailableModes.enabled(current) } }
            }

            if let message { Section("Result") { Text(message) } }
        }
        .navigationTitle("Brushing modes")
        .confirmationDialog("Write to the toothbrush?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Write") { run { try await manager.writeAvailableModes(selection) } }
        } message: {
            Text("Writes \(selection.map(OralB.modeName).joined(separator: ", ")) to the handle's mode list. You can restore your backup at any time.")
        }
        .confirmationDialog("Restore the backed-up mode list?", isPresented: $restoring, titleVisibility: .visible) {
            Button("Restore") { run { try await manager.writeAvailableModes(nil) } }
        }
    }

    func toggle(_ m: UInt8) {
        if let i = selection.firstIndex(of: m) { selection.remove(at: i) } else { selection.append(m) }
    }

    func run(_ op: @escaping () async throws -> Any) {
        Task {
            do {
                let result = try await op()
                if let after = result as? Data {
                    message = "Read back: \(AvailableModes.names(after).joined(separator: ", ")). Press the mode button on the handle to confirm."
                } else {
                    message = "Backup saved."
                }
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Sessions & history

struct DeviceSessionsView: View {
    @EnvironmentObject var manager: BrushManager
    @State private var message: String?

    var body: some View {
        List {
            Button("Read sessions stored on the brush") {
                Task {
                    do { try await manager.readDeviceSessions(); message = "\(manager.deviceSessions.count) sessions read." }
                    catch { message = error.localizedDescription }
                }
            }
            if let message { Text(message).font(.caption) }
            ForEach(manager.deviceSessions) { SessionRow(session: $0, showRaw: true) }
        }
        .navigationTitle("Stored sessions")
    }
}

struct HistoryView: View {
    @EnvironmentObject var manager: BrushManager

    var body: some View {
        HistoryList(store: manager.history)
    }
}

private struct HistoryList: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        List {
            if store.sessions.isEmpty {
                Text("Sessions appear here when the app sees a brushing session end, or after reading the brush's stored sessions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.sessions) { SessionRow(session: $0, showRaw: false) }
        }
        .navigationTitle("History")
        .toolbar { ShareLink(item: store.url) }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let showRaw: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            Text("\(session.durationSeconds / 60)m \(session.durationSeconds % 60)s · \(OralB.modeName(session.mode))")
            if showRaw {
                Text("pressure \(session.pressureSeconds, specifier: "%.1f")s, \(session.pressureWarnings) warnings, battery \(session.batteryAtEnd)%")
                    .font(.caption)
                Text(session.rawHex).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Inspector (read-only)

struct InspectorView: View {
    @EnvironmentObject var manager: BrushManager
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                Button("Read every readable characteristic") {
                    Task {
                        await manager.inspectAll()
                        exportURL = export()
                    }
                }
                Button("Subscribe to notifications") { manager.subscribeAll() }
                if let exportURL { ShareLink("Share snapshot (JSON)", item: exportURL) }
            } footer: {
                Text("Reads only. Share the snapshot to compare against the protocol notes.")
            }
            Section("Characteristics") {
                ForEach(manager.characteristics) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.knownAs ?? "unknown").font(.subheadline)
                        Text(c.uuid).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(c.properties.joined(separator: ", ")).font(.caption)
                        if let v = c.valueHex { Text(v).font(.caption.monospaced()) }
                        if let e = c.error { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Section("Notifications") {
                ForEach(manager.notifications, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
        .navigationTitle("Inspector")
    }

    func export() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oralb-snapshot.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manager.characteristics) else { return nil }
        try? data.write(to: url)
        return url
    }
}

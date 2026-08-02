import SwiftUI

struct SettingsView: View {
    @AppStorage("ioMode") private var ioModeRaw = IOMode.voiceVoice.rawValue
    @AppStorage("speechRate") private var speechRate = Constants.defaultSpeechRate
    @AppStorage("bridgeURLOverride") private var bridgeURLOverride = ""
    @AppStorage("tokenOverride") private var tokenOverride = ""

    @State private var activeBase = ""
    @State private var healthy: Bool?
    /// Mirrors the bridge, not local storage: the Mac is what actually opens things.
    @State private var autoOpen = true

    var body: some View {
        List {
            Section("Mode") {
                Picker("In and out", selection: $ioModeRaw) {
                    ForEach(IOMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section("Speech rate") {
                Slider(value: $speechRate, in: 0.35...0.6, step: 0.05)
                Button("Test voice") {
                    Speaker.shared.speak("WristDeck is ready.", rate: speechRate)
                }
            }

            Section("When a task finishes") {
                Toggle("Open the result on my Mac", isOn: $autoOpen)
                    .onChange(of: autoOpen) {
                        Task { await BridgeClient.shared.setAutoOpen(autoOpen) }
                    }
                Text("Opens the file it wrote, so it is waiting for you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Bridge") {
                HStack {
                    Circle()
                        .fill(healthy == true ? Color.green : (healthy == false ? Color.red : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(activeBase.isEmpty ? "Not connected" : activeBase)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button(checking ? "Checking..." : "Reconnect") {
                    Task {
                        checking = true
                        await AppSetup.configureClient()
                        await refresh()
                        checking = false
                    }
                }
                .disabled(checking)
            }

            Section("Connection test") {
                if diagnostics.isEmpty {
                    Text("Tap Reconnect to test")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics, id: \.url) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.url)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.result)
                                .font(.system(size: 11).bold())
                                .foregroundStyle(entry.result == "reachable" ? .green : .orange)
                        }
                    }
                }
            }

            Section("Manual override") {
                TextField("URL override", text: $bridgeURLOverride)
                    .font(.system(size: 12))
                TextField("Token override", text: $tokenOverride)
                    .font(.system(size: 12))
            }
        }
        .navigationTitle("Settings")
        .task { await refresh() }
    }

    @State private var checking = false
    @State private var diagnostics: [(url: String, result: String)] = []

    private func refresh() async {
        activeBase = await BridgeClient.shared.activeBase
        healthy = await BridgeClient.shared.healthOK()
        diagnostics = await BridgeClient.shared.diagnostics()
        autoOpen = await BridgeClient.shared.autoOpenEnabled()
    }
}

import SwiftUI

@main
struct ThreeMFPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            SettingsView()
                .frame(width: 420)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

struct SettingsView: View {
    @AppStorage("theme", store: PreviewSettings.defaults) private var theme = PreviewSettings.Theme.system.rawValue
    @AppStorage("showPlate", store: PreviewSettings.defaults) private var showPlate = false
    @AppStorage("showInfo", store: PreviewSettings.defaults) private var showInfo = false
    @AppStorage("allPlatesLayout", store: PreviewSettings.defaults) private var allPlatesLayout = PreviewSettings.AllPlatesLayout.combined.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("3MF Quick Look").font(.title2.weight(.semibold))
                    Text("Select a .3mf in Finder and press Space.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section("Preview") {
                    Picker("Appearance", selection: $theme) {
                        Text("System").tag(PreviewSettings.Theme.system.rawValue)
                        Text("Light").tag(PreviewSettings.Theme.light.rawValue)
                        Text("Dark").tag(PreviewSettings.Theme.dark.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Picker(selection: $allPlatesLayout) {
                        Text("Original layout").tag(PreviewSettings.AllPlatesLayout.combined.rawValue)
                        Text("Grid of plates").tag(PreviewSettings.AllPlatesLayout.grid.rawValue)
                    } label: {
                        Text("“All plates” view")
                        Text("Grid shows each plate up close; click one to open it")
                    }
                    Toggle(isOn: $showPlate) {
                        Text("Show build plate")
                        Text("Grid sized to the printer bed, per plate")
                    }
                    Toggle(isOn: $showInfo) {
                        Text("Show model info")
                        Text("Title, size, triangle count and print settings")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text("Changes apply the next time you open a preview.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
    }
}

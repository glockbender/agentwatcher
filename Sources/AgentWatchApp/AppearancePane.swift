import AgentWatchCore
import AppKit
import SwiftUI

struct AppearancePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        let themes = model.themes
        Form {
            Section {
                SampleRowsPreview(
                    look: themes.look, dark: themes.isDark, layout: model.layout, samples: SampleRowsPreview.phases
                )
                .frame(height: SampleRowsPreview.phasesHeight)
                .listRowInsets(EdgeInsets())
                Picker("Theme", selection: theme) {
                    ForEach(themes.themes, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                Picker("Mode", selection: mode) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                PageLink(title: "Edit Theme", detail: themes.theme.name) { model.go(.theme) }
                PageLink(title: "Your Themes", detail: "\(themes.customThemes.count)") { model.go(.themes) }
            } header: {
                Text("Theme")
            } footer: {
                SectionButtons(note: themeNote) {
                    Button("Import…") { model.importTheme() }
                    Button("Export…") { model.export(themes.theme) }
                    Button("New Theme") { model.newTheme() }
                }
            }
            Section("Widget") {
                Picker("Size", selection: scale) {
                    ForEach(WidgetSettingsStore.offeredScales, id: \.self) { scale in
                        Text("\(Int((scale * 100).rounded()))%").tag(scale)
                    }
                }
            }
        }
    }

    private var themeNote: String {
        if let problem = model.themeProblem {
            return problem
        }
        let problems = model.themes.problems
        guard problems.isEmpty else {
            return "Some theme files could not be read: " + problems.joined(separator: "; ")
        }
        return "A theme holds every colour and animation, the widget's panel included, for light and dark."
    }

    private var theme: Binding<String> {
        Binding(
            get: { model.themes.theme.name },
            set: { name in
                guard let theme = model.themes.themes.first(where: { $0.name == name }) else { return }
                model.update { model.themes.select(theme) }
            }
        )
    }

    private var mode: Binding<ThemeMode> {
        Binding(
            get: { model.themes.mode },
            set: { mode in model.update { model.themes.select(mode) } }
        )
    }

    private var scale: Binding<CGFloat> {
        Binding(
            get: {
                WidgetSettingsStore.offeredScales.min {
                    abs($0 - model.settings.scale) < abs($1 - model.settings.scale)
                } ?? 1
            },
            set: { value in model.update { model.settings.setScale(value) } }
        )
    }
}

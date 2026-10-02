import SwiftUI

/// The theme's timing: how long things take and how far they fade, in the groups the theme file
/// keeps them in. Opened from the theme editor; every change goes into the theme in use.
struct TimingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        Form {
            ThemeTimingSection(
                title: "Widget", hint: "The outline, the row card, the rows' moves, the lamps' dimming.",
                fields: WidgetTheme.Timing.Widget.fields, group: \.widget, model: model)
            ThemeTimingSection(
                title: "Menu bar", hint: "The Counts icon's empty marks, and how far its marks dim.",
                fields: WidgetTheme.Timing.MenuBar.fields, group: \.menuBar, model: model)
            ThemeTimingSection(
                title: "Full-screen dot", hint: "Shown where the menu bar is hidden.",
                fields: WidgetTheme.Timing.Dot.fields, group: \.dot, model: model
            ) {
                Picker("Corner", selection: corner) {
                    Text("Top left").tag(false)
                    Text("Top right").tag(true)
                }
            }
            Section {
            } footer: {
                SectionButtons(note: model.themeProblem) {
                    Button("Restore Default Timing") { model.changeTheme { $0.timing = WidgetTheme.Timing() } }
                }
            }
        }
    }

    private var corner: Binding<Bool> {
        Binding(
            get: { model.themes.theme.timing.dot.clamped.isOnTheRight },
            set: { right in model.changeTheme { $0.timing.dot.corner = right ? "topRight" : "topLeft" } }
        )
    }
}

private struct ThemeTimingSection<Group, Extra: View>: View {
    let title: String
    let hint: String
    let fields: [WidgetTheme.Timing.Field<Group>]
    let group: WritableKeyPath<WidgetTheme.Timing, Group>
    @ObservedObject var model: SettingsModel
    @ViewBuilder var extra: Extra

    var body: some View {
        Section {
            extra
            ForEach(fields.indices, id: \.self) { index in
                let field = fields[index]
                LabeledContent(field.title) {
                    CycleSlider(
                        value: binding(field), range: field.range, unit: unit(field.unit),
                        format: field.unit == .fraction ? "%.2f" : field.unit == .points ? "%.0f" : "%.1f")
                }
            }
        } header: {
            Heading(title: title, hint: hint)
        }
    }

    private func unit(_ unit: WidgetTheme.Timing.Field<Group>.Unit) -> String {
        switch unit {
        case .seconds: "s"
        case .fraction: ""
        case .points: "pt"
        }
    }

    private func binding(_ field: WidgetTheme.Timing.Field<Group>) -> Binding<Double> {
        Binding(
            get: { model.themes.theme.timing.clamped[keyPath: group][keyPath: field.path] },
            set: { value in model.changeTheme { $0.timing[keyPath: group][keyPath: field.path] = value } }
        )
    }
}

extension ThemeTimingSection where Extra == EmptyView {
    init(
        title: String, hint: String, fields: [WidgetTheme.Timing.Field<Group>],
        group: WritableKeyPath<WidgetTheme.Timing, Group>, model: SettingsModel
    ) {
        self.init(title: title, hint: hint, fields: fields, group: group, model: model) { EmptyView() }
    }
}

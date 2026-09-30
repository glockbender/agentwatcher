import AgentWatchCore
import AppKit
import SwiftUI

// MARK: - The editor

/// Every setting a theme holds, with the real views it draws beside them.
///
/// It edits the theme in use, so the widget, the menu bar and the menu show each change as it
/// is made. The built-in theme is copied on the first change (`ThemeStore.editable`).
struct ThemeEditorPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        let look = model.editedLook
        Form {
            ThemeNameSection(model: model)
            Section {
                ThemeRowsPreview(look: look, layout: model.layout)
                    .frame(height: ThemeRowsPreview.height)
                    .listRowInsets(EdgeInsets())
                ColorPicker("Background", selection: colour(look.widgetBackground.color) { $0.setBackground($1) })
                Picker("Material", selection: material) {
                    ForEach(WidgetMaterial.allCases, id: \.self) { material in
                        Text(
                            material.needsLiquidGlass && !WidgetMaterial.systemHasLiquidGlass
                                ? "\(material.name) (macOS 26)" : material.name
                        )
                        .tag(material)
                    }
                }
                Slider(value: opacity, in: WidgetTheme.opacityRange) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.dotted")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                .help("\(Int((look.widgetOpacity * 100).rounded()))%")
                .disabled(look.widgetMaterial.drawn == .solid)
            } header: {
                Text("Widget")
            } footer: {
                Footnote(materialNote(look.widgetMaterial))
            }
            LampsSection(model: model, look: look)
            StatesSection(model: model, look: look)
            SphereSection(model: model, look: look)
            MenuSection(model: model, look: look)
            Section("Other colours") {
                ForEach(WidgetTheme.Role.allCases, id: \.self) { role in
                    ColorPicker(role.name, selection: colour(look.color(role)) { $0.setColor($1, for: role) })
                }
            }
        }
    }

    private func colour(_ current: NSColor, _ write: @escaping (inout WidgetTheme.Look, NSColor) -> Void)
        -> Binding<Color>
    {
        Binding(
            get: { Color(nsColor: current) },
            set: { chosen in model.editTheme { write(&$0, NSColor(chosen)) } }
        )
    }

    private var material: Binding<WidgetMaterial> {
        Binding(
            get: { model.editedLook.widgetMaterial },
            set: { material in model.editTheme { $0.widgetMaterial = material } }
        )
    }

    private var opacity: Binding<Double> {
        Binding(
            get: { Double(model.editedLook.widgetOpacity) },
            set: { value in model.editTheme { $0.widgetOpacity = CGFloat(value) } }
        )
    }

    private func materialNote(_ material: WidgetMaterial) -> String {
        if material.needsLiquidGlass && !WidgetMaterial.systemHasLiquidGlass {
            return "Glass needs macOS 26. Until then the widget is drawn frosted, and a Mac that has it draws glass."
        }
        return switch material.drawn {
        case .glass: "Glass is recommended: the desktop shows through, and the colour keeps text readable."
        case .clearGlass: "Clear glass shows more of the desktop. Best on a quiet wallpaper."
        case .frosted: "Frosted blurs what is behind the widget."
        case .solid: "Solid hides the desktop entirely, so opacity does not apply. Best on a busy wallpaper."
        }
    }
}

/// The theme's name, which look an edit goes into, and what went wrong with the last one.
private struct ThemeNameSection: View {
    @ObservedObject var model: SettingsModel
    @State private var name = ""

    var body: some View {
        Section {
            TextField("Name", text: $name)
                .onSubmit { rename() }
            Picker("Changes go into", selection: $model.themeScope) {
                ForEach(SettingsModel.ThemeScope.allCases, id: \.self) { scope in
                    Text(scope.name).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Footnote(note)
        }
        .onAppear { name = model.themes.theme.name }
        .onChange(of: model.revision) { name = model.themes.theme.name }
    }

    private var note: String {
        if let problem = model.themeProblem {
            return problem
        }
        if model.themes.isBuiltIn(model.themes.theme) {
            return "Default is built in. The first change makes a copy of it, and the copy is used from then on."
        }
        return "Every change is used and saved at once. A theme has a look for light and one for dark; "
            + "“Light and Dark” changes both."
    }

    private func rename() {
        let chosen = name
        model.changeTheme { $0.name = chosen }
        name = model.themes.theme.name
    }
}

/// A lamp's four settings, the way the lamp tab laid them out before themes.
private struct LampsSection: View {
    @ObservedObject var model: SettingsModel
    let look: WidgetTheme.Look

    var body: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach(["State", "Color", "Motion", "To color", "Full cycle", ""], id: \.self) { title in
                        Text(title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(SessionPhase.allCases, id: \.self) { phase in
                    LampRow(model: model, phase: phase, look: look)
                }
            }
        } header: {
            Heading(
                title: "Lamps",
                hint: "The dot at the start of each row in the widget. Hover a state's name to see when it happens.")
        } footer: {
            SectionButtons(
                note:
                    "Dim changes brightness. Two-color fade changes color. Full cycle sets the time out and back."
            ) {
                Button("Restore Default Lamps") {
                    model.editTheme { $0.lamps = WidgetTheme.lamps(from: LampScheme()) }
                }
            }
        }
    }
}

private struct LampRow: View {
    @ObservedObject var model: SettingsModel
    let phase: SessionPhase
    let look: WidgetTheme.Look

    var body: some View {
        let style = look.lampScheme.style(for: phase)
        GridRow {
            Text(phase.settingsName)
                .lineLimit(2)
                .frame(width: 110, alignment: .leading)
                .help(phase.explanation)
            ColorPicker("", selection: change(Color(nsColor: style.color)) { $0.color = NSColor($1) })
                .labelsHidden()
            Picker("", selection: change(style.motion) { $0.motion = $1 }) {
                ForEach(SessionLampAppearance.Motion.allCases, id: \.self) { motion in
                    Text(motion.title).tag(motion)
                }
            }
            .labelsHidden()
            .fixedSize()
            ColorPicker("", selection: change(Color(nsColor: style.gradientColor)) { $0.gradientColor = NSColor($1) })
                .labelsHidden()
                .disabled(style.motion != .gradient)
                .help("The second color. Used only by Two-color fade.")
            CycleSlider(
                value: change(style.animationCycle) { $0.animationCycle = $1 }, range: LampStyle.animationCycleRange
            )
            .disabled(style.motion == .steady)
            LampSwatch(phase: phase, look: look)
                .frame(width: LampSwatch.size.width, height: LampSwatch.size.height)
        }
    }

    private func change<Value>(_ current: Value, _ write: @escaping (inout LampStyle, Value) -> Void)
        -> Binding<Value>
    {
        Binding(
            get: { current },
            set: { value in
                model.editTheme { look in
                    var style = look.lampScheme.style(for: phase)
                    write(&style, value)
                    look.setLampStyle(style, for: phase)
                }
            }
        )
    }
}

/// Seconds for one full animation, out and back, with the number beside it.
private struct CycleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "s"

    var body: some View {
        HStack(spacing: 4) {
            Slider(value: $value, in: range).frame(width: 64)
            Text(String(format: "%.1f \(unit)", value))
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .leading)
        }
        .help("Seconds for one complete animation, out and back.")
    }
}

/// The four states the menu bar and the menu count, each coloured and moved.
private struct StatesSection: View {
    @ObservedObject var model: SettingsModel
    let look: WidgetTheme.Look

    var body: some View {
        Section {
            Toggle("Match the menu bar and the menu to the lamps", isOn: followsLamps)
            // Two tables rather than one six columns wide, which did not fit the window.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach(["State", "Color from", "Color"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    StateColourRow(model: model, attention: attention, look: look)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach(["State", "Motion", "To color", "Full cycle"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    StateMotionRow(model: model, attention: attention, look: look)
                }
            }
            MenuBarIconPreview(look: look)
                .frame(height: MenuBarIconPreview.height)
        } header: {
            Heading(
                title: "Menu bar",
                hint: "The four states the menu bar icon counts. Motion is the Counts icon's, and the menu's if asked.")
        } footer: {
            Footnote(
                "A state can take the colour of one of its own lamps: Needs You from Waiting for you, Failed or "
                    + "Terminal closed, and so on. Lamp colours were chosen for the widget's background, so check "
                    + "them on a light menu bar too.")
        }
    }

    private var followsLamps: Binding<Bool> {
        Binding(
            get: { model.editedLook.followsLamps },
            set: { on in model.editTheme { $0.setFollowsLamps(on) } }
        )
    }
}

private struct StateColourRow: View {
    @ObservedObject var model: SettingsModel
    let attention: SessionAttention
    let look: WidgetTheme.Look

    var body: some View {
        let lamp = look.lamp(for: attention)
        GridRow {
            Text(attention.name).frame(width: StateColourRow.nameWidth, alignment: .leading)
            Picker("", selection: source) {
                Text("Its own").tag(WidgetTheme.ColourSource.own)
                Text("Most sessions").tag(WidgetTheme.ColourSource.mostSessions)
                Section("One lamp") {
                    ForEach(attention.phases, id: \.self) { phase in
                        Text(phase.settingsName).tag(WidgetTheme.ColourSource.lamp(phase))
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Most sessions: the lamp of the phase most of this state's sessions are in right now.")
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(nsColor: look.accent(for: attention)) },
                    set: { chosen in model.editTheme { $0.setOwnAccent(NSColor(chosen), for: attention) } }
                )
            )
            .labelsHidden()
            .disabled(lamp != nil)
            .help(lamp.map { "Taken from the \($0.settingsName) lamp." } ?? "This state's own colour.")
        }
    }

    static let nameWidth: CGFloat = 80

    private var source: Binding<WidgetTheme.ColourSource> {
        Binding(
            get: { model.editedLook.colourSource(for: attention) },
            set: { source in model.editTheme { $0.setColourSource(source, for: attention) } }
        )
    }
}

private struct StateMotionRow: View {
    @ObservedObject var model: SettingsModel
    let attention: SessionAttention
    let look: WidgetTheme.Look

    var body: some View {
        let style = look.markStyle(for: attention)
        GridRow {
            Text(attention.name).frame(width: StateColourRow.nameWidth, alignment: .leading)
            Picker("", selection: binding(style, \.motion)) {
                ForEach(SessionLampAppearance.Motion.allCases, id: \.self) { motion in
                    Text(motion.title).tag(motion)
                }
            }
            .labelsHidden()
            .fixedSize()
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(nsColor: style.gradientColor) },
                    set: { chosen in write(style) { $0.gradientColor = NSColor(chosen) } }
                )
            )
            .labelsHidden()
            .disabled(style.motion != .gradient)
            CycleSlider(value: binding(style, \.animationCycle), range: LampStyle.animationCycleRange)
                .disabled(style.motion == .steady)
        }
    }

    private func binding<Value>(_ style: LampStyle, _ path: WritableKeyPath<LampStyle, Value>) -> Binding<Value> {
        Binding(get: { style[keyPath: path] }, set: { value in write(style) { $0[keyPath: path] = value } })
    }

    private func write(_ style: LampStyle, _ change: (inout LampStyle) -> Void) {
        var changed = style
        change(&changed)
        model.editTheme {
            $0.setMarkMotion(
                changed.motion, fadeTo: changed.gradientColor, cycle: changed.animationCycle, for: attention)
        }
    }
}

/// The sphere's own movements.
private struct SphereSection: View {
    @ObservedObject var model: SettingsModel
    let look: WidgetTheme.Look

    var body: some View {
        let sphere = look.sphereMotion
        Section {
            Toggle("Halo in the colour of the most important state", isOn: field(\.halo))
            LabeledContent("Halo breathes while a session needs you") {
                HStack {
                    CycleSlider(value: field(\.haloCycle), range: WidgetTheme.Sphere.haloCycleRange)
                        .disabled(!sphere.halo || !sphere.haloBreathes)
                    Toggle("", isOn: field(\.haloBreathes)).labelsHidden().toggleStyle(.switch)
                        .disabled(!sphere.halo)
                }
            }
            LabeledContent("Colours sway while anything works or waits") {
                HStack {
                    CycleSlider(value: field(\.swayDegrees), range: WidgetTheme.Sphere.swayDegreesRange, unit: "°")
                        .help("How far the colours sway each way.")
                        .disabled(!sphere.sway)
                    CycleSlider(value: field(\.swayCycle), range: WidgetTheme.Sphere.swayCycleRange)
                        .disabled(!sphere.sway)
                    Toggle("", isOn: field(\.sway)).labelsHidden().toggleStyle(.switch)
                }
            }
            LabeledContent("Swells once when a count changes") {
                HStack {
                    CycleSlider(value: field(\.swellSeconds), range: WidgetTheme.Sphere.swellSecondsRange)
                        .help("How long the swell takes.")
                        .disabled(!sphere.swell)
                    Toggle("", isOn: field(\.swell)).labelsHidden().toggleStyle(.switch)
                }
            }
        } header: {
            Heading(title: "Sphere", hint: "The Sphere icon's movements. Its colours are the states' above.")
        } footer: {
            SectionButtons(note: "The examples above change their counts every three seconds.") {
                Button("Restore Default Sphere") { model.editTheme { $0.sphere = WidgetTheme.Sphere() } }
            }
        }
    }

    private func field<Value>(_ path: WritableKeyPath<WidgetTheme.Sphere, Value>) -> Binding<Value> {
        Binding(
            get: { model.editedLook.sphereMotion[keyPath: path] },
            set: { value in model.editTheme { $0.sphere[keyPath: path] = value } }
        )
    }
}

/// How the menu's session lines mark their sessions.
private struct MenuSection: View {
    @ObservedObject var model: SettingsModel
    let look: WidgetTheme.Look

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Mark colour", selection: colours) {
                        Text("Its state's").tag(WidgetTheme.MenuColors.state)
                        Text("Its session's lamp").tag(WidgetTheme.MenuColors.lamp)
                    }
                    Picker("Mark motion", selection: motion) {
                        Text("None").tag(WidgetTheme.MenuMotion.none)
                        Text("Like its state").tag(WidgetTheme.MenuMotion.state)
                        Text("Like its session's lamp").tag(WidgetTheme.MenuMotion.lamp)
                    }
                }
                MenuLinesPreview(look: look)
                    .frame(width: MenuLinesPreview.width, height: MenuLinesPreview.height)
            }
        } header: {
            Heading(title: "Menu", hint: "The mark at the start of each session line in the menu.")
        } footer: {
            Footnote(
                "A line stands for one session, so “its session's lamp” is exactly the lamp its row has in the "
                    + "widget. Moving marks are drawn only while the menu is open.")
        }
    }

    private var colours: Binding<WidgetTheme.MenuColors> {
        Binding(
            get: { model.editedLook.menuColors },
            set: { value in model.editTheme { $0.menuColors = value } }
        )
    }

    private var motion: Binding<WidgetTheme.MenuMotion> {
        Binding(
            get: { model.editedLook.menuMotion },
            set: { value in model.editTheme { $0.menuMotion = value } }
        )
    }
}

// MARK: - The list of themes

/// The themes a person made or brought in: edit, export or delete each.
struct ThemesPane: View {
    @ObservedObject var model: SettingsModel
    @State private var deleting: WidgetTheme?

    var body: some View {
        let _ = model.revision
        let custom = model.themes.customThemes
        Form {
            Section {
                if custom.isEmpty {
                    Text("No themes of your own yet.").foregroundStyle(.secondary)
                }
                ForEach(custom, id: \.name) { theme in
                    HStack {
                        Text(theme.name)
                        if theme.name == model.themes.theme.name {
                            Text("In use").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { model.edit(theme) }
                        Button("Duplicate") { model.duplicate(theme) }
                        Button("Export…") { model.export(theme) }
                        Button("Delete…") { deleting = theme }
                    }
                }
            } header: {
                Text("Your themes")
            } footer: {
                SectionButtons(note: model.themeProblem ?? model.themeFolderNote) {
                    Button("Import…") { model.importTheme() }
                    Button("New Theme") { model.newTheme() }
                    Button("Show Theme Folder") { model.showThemeFolder() }
                }
            }
        }
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text(
                "Its file goes to the Trash, where it can be put back. If it is in use, the built-in theme takes over.")
        }
    }
}

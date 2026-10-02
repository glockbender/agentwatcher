import AgentWatchCore
import AppKit
import SwiftUI

struct MenuBarPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let settings = model.settings
        let iconShows = settings.menuBarIconAttentions
        Form {
            Section {
                Picker("Style", selection: iconStyle) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.name).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    Toggle(attention.name, isOn: iconShowing(attention))
                        .disabled(iconShows.contains(attention) && iconShows.count == 1)
                }
            } header: {
                Text("Icon")
            } footer: {
                Footnote("At least one state stays in the icon.")
            }
            Section {
                Toggle("List sessions in the menu", isOn: listsSessions)
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    Toggle(attention.name, isOn: menuListing(attention))
                        .disabled(!settings.listsSessionsInMenu)
                }
                Stepper(
                    "Sessions before scrolling: \(settings.menuSessionsBeforeScrolling)",
                    value: sessionsBeforeScrolling,
                    in: WidgetSettingsStore.menuSessionsBeforeScrollingRange
                )
                .disabled(!settings.listsSessionsInMenu)
            } header: {
                Text("Menu")
            } footer: {
                Footnote(
                    "Listed sessions appear under the summary line; clicking one brings its window forward. "
                        + "Past the number above, the list scrolls. Arrow keys skip the list, "
                        + "so a session is chosen with the pointer."
                )
            }
        }
    }

    private var iconStyle: Binding<MenuBarIconStyle> {
        Binding(
            get: { model.settings.menuBarIconStyle },
            set: { style in model.update { model.settings.setMenuBarIconStyle(style) } }
        )
    }

    private func iconShowing(_ attention: SessionAttention) -> Binding<Bool> {
        Binding(
            get: { model.settings.menuBarIconAttentions.contains(attention) },
            set: { on in model.update { model.settings.setMenuBarIconShows(attention, on) } }
        )
    }

    private var listsSessions: Binding<Bool> {
        Binding(
            get: { model.settings.listsSessionsInMenu },
            set: { on in model.update { model.settings.setListsSessionsInMenu(on) } }
        )
    }

    private var sessionsBeforeScrolling: Binding<Int> {
        Binding(
            get: { model.settings.menuSessionsBeforeScrolling },
            set: { count in model.update { model.settings.setMenuSessionsBeforeScrolling(count) } }
        )
    }

    private func menuListing(_ attention: SessionAttention) -> Binding<Bool> {
        Binding(
            get: { model.settings.menuSessionAttentions.contains(attention) },
            set: { on in model.update { model.settings.setMenuLists(attention, on) } }
        )
    }
}

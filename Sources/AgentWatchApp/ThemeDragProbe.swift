#if DEBUG
    import AgentWatchCore
    import AppKit

    /// Opens the theme editor and changes a lamp's colour the way a dragged colour wheel does,
    /// writing the process's memory after each stretch, then closes the window and quits.
    ///
    /// Run on a debug copy with a copy of the state, so the widget has real rows to rebuild:
    ///
    ///     open --env AGENT_WATCH_SUPPORT_DIR=<copy> --env AGENT_WATCH_THEME_DRAG_PROBE=<file> -n <app>
    ///
    /// 240 changes spaced 30 ms apart, then 120 in one turn of the run loop, which is what a
    /// colour wheel does while it is held. Measured on macOS 15.3.1 with 19 rows: rebuilding on
    /// every change took the process from 92 to 373 MB (144 MB three seconds later), rebuilding
    /// once per turn (`CoalescedWork`) kept it at 92 MB, and the spaced changes stayed at 92 MB
    /// either way, so the heap does not grow.
    /// The window opens on screen and takes the focus for about twenty seconds.
    @MainActor
    final class ThemeDragProbe {
        private let window: SettingsWindowController
        private let file: URL
        private var lines: [String] = []
        private var step = 0
        private var timer: Timer?

        init(window: SettingsWindowController, file: URL) {
            self.window = window
            self.file = file
        }

        func start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated { self?.openEditor() }
            }
        }

        private func openEditor() {
            note("before settings")
            window.present()
            window.model.go(.theme)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.drag() }
            }
        }

        private func drag() {
            note("editor open")
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        private func tick() {
            step += 1
            change(step)
            if step % 60 == 0 { note("after \(step) spaced changes") }
            guard step == 240 else { return }
            timer?.invalidate()
            for inTurn in 0..<120 { change(1_000 + inTurn) }
            note("after 120 changes in one turn")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    self?.note("3 s later")
                    self?.window.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.note("3 s after closing the window")
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
        }

        private func change(_ step: Int) {
            let colour = NSColor(hue: CGFloat(step % 120) / 120, saturation: 1, brightness: 1, alpha: 1)
            window.model.editTheme { look in
                var lamp = look.lampScheme.style(for: .waitingForUser)
                lamp.color = colour
                look.setLampStyle(lamp, for: .waitingForUser)
            }
        }

        private func note(_ label: String) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            var heap = malloc_statistics_t()
            malloc_zone_statistics(nil, &heap)
            lines.append(
                "\(label): \(info.phys_footprint / 1_048_576) MB, peak \(info.ledger_phys_footprint_peak / 1_048_576) MB, "
                    + "heap in use \(heap.size_in_use / 1_048_576) MB")
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
#endif

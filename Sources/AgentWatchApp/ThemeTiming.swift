import Foundation

extension WidgetTheme {
    /// The numbers behind how things move and fade, the same in light and dark: in groups, as
    /// the settings window's Timing page shows them. What a file leaves out is the default.
    struct Timing: Codable, Equatable {
        var widget = Widget()
        var menuBar = MenuBar()
        var dot = Dot()

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            widget = try values.decode(.widget, or: Widget())
            menuBar = try values.decode(.menuBar, or: MenuBar())
            dot = try values.decode(.dot, or: Dot())
        }

        var clamped: Timing {
            var timing = self
            timing.widget = widget.clamped
            timing.menuBar = menuBar.clamped
            timing.dot = dot.clamped
            return timing
        }

        struct Widget: Codable, Equatable {
            /// The outline flashed when the widget is shown: for how long, each pulse, how faint.
            var highlightSeconds: Double = 5
            var highlightPulseSeconds: Double = 0.5
            var highlightPulseLow: Double = 0.2
            /// How long the pointer rests on a row before its card opens.
            var hoverCardDelay: Double = 0.5
            /// How long a row takes to reach its new place, and the order example's step.
            var rowMoveSeconds: Double = 0.45
            var orderExampleStep: Double = 2
            /// How far a dimming lamp fades: a disc, and a ring, which needs more to register.
            var lampDimDisc: Double = 0.55
            var lampDimRing: Double = 0.3
            /// The wash under a hovered row, on a light and on a dark background.
            var hoverWashLight: Double = 0.08
            var hoverWashDark: Double = 0.12
            /// The border of the hidden-sessions counter while one of them needs you, and otherwise.
            var counterBorder: Double = 0.6
            var counterBorderQuiet: Double = 0.25
            /// How strongly the theme's colour tints glass; clear glass takes half.
            var glassTint: Double = 0.5

            init() {}

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let standard = Widget()
                highlightSeconds = try values.decode(.highlightSeconds, or: standard.highlightSeconds)
                highlightPulseSeconds = try values.decode(.highlightPulseSeconds, or: standard.highlightPulseSeconds)
                highlightPulseLow = try values.decode(.highlightPulseLow, or: standard.highlightPulseLow)
                hoverCardDelay = try values.decode(.hoverCardDelay, or: standard.hoverCardDelay)
                rowMoveSeconds = try values.decode(.rowMoveSeconds, or: standard.rowMoveSeconds)
                orderExampleStep = try values.decode(.orderExampleStep, or: standard.orderExampleStep)
                lampDimDisc = try values.decode(.lampDimDisc, or: standard.lampDimDisc)
                lampDimRing = try values.decode(.lampDimRing, or: standard.lampDimRing)
                hoverWashLight = try values.decode(.hoverWashLight, or: standard.hoverWashLight)
                hoverWashDark = try values.decode(.hoverWashDark, or: standard.hoverWashDark)
                counterBorder = try values.decode(.counterBorder, or: standard.counterBorder)
                counterBorderQuiet = try values.decode(.counterBorderQuiet, or: standard.counterBorderQuiet)
                glassTint = try values.decode(.glassTint, or: standard.glassTint)
            }

            static let fields: [Field<Widget>] = [
                Field("Highlight lasts", \.highlightSeconds, 1...15),
                Field("Highlight pulse", \.highlightPulseSeconds, 0.2...2),
                Field("Highlight fades to", \.highlightPulseLow, 0...1, unit: .fraction),
                Field("Row card opens after", \.hoverCardDelay, 0...3),
                Field("Row moves in", \.rowMoveSeconds, 0.1...2),
                Field("Order example changes every", \.orderExampleStep, 1...6),
                Field("Dimming disc lamp fades to", \.lampDimDisc, 0...1, unit: .fraction),
                Field("Dimming ring lamp fades to", \.lampDimRing, 0...1, unit: .fraction),
                Field("Hovered row wash, light", \.hoverWashLight, 0...0.5, unit: .fraction),
                Field("Hovered row wash, dark", \.hoverWashDark, 0...0.5, unit: .fraction),
                Field("Counter border, needs you", \.counterBorder, 0...1, unit: .fraction),
                Field("Counter border, otherwise", \.counterBorderQuiet, 0...1, unit: .fraction),
                Field("Glass tint", \.glassTint, 0...1, unit: .fraction),
            ]

            var clamped: Widget { Self.fields.clamp(self, to: Widget()) }
        }

        struct MenuBar: Codable, Equatable {
            /// What an empty mark is drawn at.
            var emptyMark: Double = 0.4
            /// How far a dimming mark fades: needs you, and every other state.
            var dimNeedsYou: Double = 0.65
            var dimOthers: Double = 0.45

            init() {}

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let standard = MenuBar()
                emptyMark = try values.decode(.emptyMark, or: standard.emptyMark)
                dimNeedsYou = try values.decode(.dimNeedsYou, or: standard.dimNeedsYou)
                dimOthers = try values.decode(.dimOthers, or: standard.dimOthers)
            }

            static let fields: [Field<MenuBar>] = [
                Field("Empty mark", \.emptyMark, 0...1, unit: .fraction),
                Field("Needs You dims by", \.dimNeedsYou, 0...1, unit: .fraction),
                Field("Other states dim by", \.dimOthers, 0...1, unit: .fraction),
            ]

            var clamped: MenuBar { Self.fields.clamp(self, to: MenuBar()) }
        }

        /// Placement of the waiting beacon. The dot key also reads older themes.
        struct Dot: Codable, Equatable {
            var ringDiameter: Double = 24
            var inset: Double = 28
            var corner = "topRight"

            init() {}

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let standard = Dot()
                ringDiameter = try values.decode(.ringDiameter, or: standard.ringDiameter)
                inset = try values.decode(.inset, or: standard.inset)
                corner = try values.decode(.corner, or: standard.corner)
            }

            static let fields: [Field<Dot>] = [
                Field("Ring diameter", \.ringDiameter, 20...34, unit: .points),
                Field("Distance from the side", \.inset, 0...80, unit: .points),
            ]

            var isOnTheRight: Bool { corner != "topLeft" }

            var clamped: Dot {
                var dot = Self.fields.clamp(self, to: Dot())
                dot.corner = isOnTheRight ? "topRight" : "topLeft"
                return dot
            }
        }

        /// One number the Timing page offers, and the range a file is held to.
        struct Field<Group>: @unchecked Sendable {
            enum Unit {
                case seconds, fraction, points
            }

            let title: String
            let path: WritableKeyPath<Group, Double>
            let range: ClosedRange<Double>
            let unit: Unit

            init(
                _ title: String, _ path: WritableKeyPath<Group, Double>, _ range: ClosedRange<Double>,
                unit: Unit = .seconds
            ) {
                self.title = title
                self.path = path
                self.range = range
                self.unit = unit
            }
        }
    }
}

extension Array {
    fileprivate func clamp<Group>(_ group: Group, to standard: Group) -> Group
    where Element == WidgetTheme.Timing.Field<Group> {
        var clamped = group
        for field in self {
            clamped[keyPath: field.path] = group[keyPath: field.path].clamped(
                to: field.range, or: standard[keyPath: field.path])
        }
        return clamped
    }
}

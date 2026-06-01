import SwiftUI

public enum GlassBackgroundDisplayMode {
    case always
    case implicit
    case never
}

public extension View {
    @ViewBuilder
    func glassBackgroundEffect(displayMode: GlassBackgroundDisplayMode = .always) -> some View {
        switch displayMode {
        case .never:
            self
        case .always, .implicit:
            if #available(iOS 26, macOS 26, *) {
                self.background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.06))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
            } else {
                self.background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
            }
        }
    }
}

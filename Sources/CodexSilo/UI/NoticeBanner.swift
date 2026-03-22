import SwiftUI

struct NoticeBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let notice: NoticeMessage?

    var body: some View {
        if let notice {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: notice.style.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(notice.style.accentColor)
                    .symbolRenderingMode(.hierarchical)

                Text(notice.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 560, alignment: .leading)
            .noticeSurface(style: notice.style)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12),
                radius: 18,
                y: 10
            )
            .transition(
                .opacity
                    .combined(with: .scale(scale: 0.96, anchor: .bottom))
                    .combined(with: .move(edge: .bottom))
            )
        }
    }
}

private extension View {
    @ViewBuilder
    func noticeSurface(style: NoticeStyle) -> some View {
        self
            .modifier(NoticeGlassSurfaceModifier(style: style))
    }
}

private struct NoticeGlassSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let style: NoticeStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        content
            .background {
                ZStack {
                    if #available(macOS 26.0, *) {
                        shape
                            .fill(.clear)
                            .glassEffect(.regular.tint(baseGlassTint), in: shape)
                    } else {
                        shape
                            .fill(.ultraThinMaterial)
                    }

                    shape
                        .fill(surfaceHighlight)

                    shape
                        .fill(style.accentColor.opacity(colorScheme == .dark ? 0.06 : 0.035))
                }
            }
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }

    private var baseGlassTint: Color {
        style.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var surfaceHighlight: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.035)
            : Color.white.opacity(0.16)
    }

    private var borderColor: Color {
        Color(nsColor: .separatorColor)
            .opacity(colorScheme == .dark ? 0.38 : 0.24)
    }
}

private extension NoticeStyle {
    var accentColor: Color {
        switch self {
        case .success:
            return .mint
        case .info:
            return .blue
        case .error:
            return .red
        }
    }

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

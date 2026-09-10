import SwiftUI

// yaply custom popup kit
// ----------------------
// Replaces UIKit-flavoured `.sheet` / `.alert` / `.confirmationDialog`
// presentations with a web-styled surface: a card that rises from the
// bottom over a dimmed scrim, with rounded top corners, a grab handle, a
// hairline border and a soft shadow — mirroring the web app's Radix
// Dialog treatment (`bg-card`, `rounded-2xl`, `border-border`,
// backdrop blur) while keeping bottom-sheet ergonomics on touch.
//
// Entry points:
//   .yaplyPopup(isPresented:)        — arbitrary content
//   .yaplyPopup(item:)               — arbitrary content, item-driven
//   .yaplyConfirm(isPresented:…)     — destructive / confirm dialog
//   .yaplyConfirm(item:)             — same, item-driven
//   YaplySheetScaffold { … }         — header + scroll body for form sheets
//
// Inside popup content, call `@Environment(\.yaplyPopupDismiss)` to close
// with the exit animation.

// MARK: - Dismiss environment

private struct YaplyPopupDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Closes the enclosing `yaplyPopup` with its exit animation. No-op
    /// outside a popup.
    var yaplyPopupDismiss: () -> Void {
        get { self[YaplyPopupDismissKey.self] }
        set { self[YaplyPopupDismissKey.self] = newValue }
    }
}

// MARK: - Container

private struct YaplyPopupContainer<PopupContent: View>: View {
    @Binding var isPresented: Bool
    let dismissOnBackdrop: Bool
    @ViewBuilder let content: () -> PopupContent

    @Environment(\.colorScheme) private var scheme
    @State private var shown = false

    private var scrimOpacity: Double {
        guard shown else { return 0 }
        return scheme == .dark ? 0.6 : 0.32
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(scrimOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if dismissOnBackdrop { close() } }
                .animation(.easeOut(duration: 0.28), value: shown)

            if shown {
                YaplyPopupChrome { content() }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: 560)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.yaplyPopupDismiss, close)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { shown = true }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.94)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { isPresented = false }
    }
}

/// The visual card shell — grab handle, surface fill, rounded top,
/// hairline border, shadow. Exposed so bespoke sheets can reuse it.
struct YaplyPopupChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.yaplySecondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            content()
        }
        .frame(maxWidth: .infinity)
        .background(Color.yaplySurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.yaplyBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 10)
        .padding(.bottom, 6)
    }
}

// MARK: - View modifiers

extension View {
    func yaplyPopup<C: View>(
        isPresented: Binding<Bool>,
        dismissOnBackdrop: Bool = true,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            YaplyPopupContainer(
                isPresented: isPresented,
                dismissOnBackdrop: dismissOnBackdrop,
                content: content
            )
            .presentationBackground(.clear)
        }
    }

    func yaplyPopup<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        dismissOnBackdrop: Bool = true,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        fullScreenCover(item: item) { value in
            YaplyPopupContainer(
                isPresented: Binding(
                    get: { item.wrappedValue != nil },
                    set: { if !$0 { item.wrappedValue = nil } }
                ),
                dismissOnBackdrop: dismissOnBackdrop,
                content: { content(value) }
            )
            .presentationBackground(.clear)
        }
    }
}

// MARK: - Confirm / destructive dialog

struct YaplyConfirmConfig: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var icon: String = "exclamationmark.triangle.fill"
    var confirmLabel: String = "Confirm"
    var cancelLabel: String = "Cancel"
    var isDestructive: Bool = true
    var onConfirm: () -> Void
}

struct YaplyConfirmView: View {
    let config: YaplyConfirmConfig
    @Environment(\.yaplyPopupDismiss) private var dismiss

    private var tint: Color { config.isDestructive ? .yaplyDanger : .yaplyAccent }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: config.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text(config.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Text(config.message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplySecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(config.cancelLabel) { dismiss() }
                    .buttonStyle(YaplyOutlineButtonStyle())
                Button(config.confirmLabel) {
                    // Run the action before dismissing so it can still read any
                    // @State that the presenting binding clears on close.
                    config.onConfirm()
                    dismiss()
                }
                .buttonStyle(YaplyFilledButtonStyle(tint: tint))
            }
            .padding(.top, 2)
        }
        .padding(20)
        .padding(.bottom, 8)
    }
}

extension View {
    func yaplyConfirm(item: Binding<YaplyConfirmConfig?>) -> some View {
        yaplyPopup(item: item) { config in
            YaplyConfirmView(config: config)
        }
    }

    func yaplyConfirm(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        icon: String = "exclamationmark.triangle.fill",
        confirmLabel: String = "Confirm",
        cancelLabel: String = "Cancel",
        isDestructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) -> some View {
        yaplyPopup(isPresented: isPresented) {
            YaplyConfirmView(config: YaplyConfirmConfig(
                title: title, message: message, icon: icon,
                confirmLabel: confirmLabel, cancelLabel: cancelLabel,
                isDestructive: isDestructive, onConfirm: onConfirm
            ))
        }
    }
}

// MARK: - Info alert (single acknowledge button)

struct YaplyInfoView: View {
    let title: String
    let message: String
    var icon: String = "exclamationmark.circle.fill"
    var buttonLabel: String = "OK"
    @Environment(\.yaplyPopupDismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.yaplyAccent.opacity(0.14)).frame(width: 52, height: 52)
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.yaplyAccent)
            }
            .padding(.top, 8)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplySecondary)
                    .multilineTextAlignment(.center)
            }
            Button(buttonLabel) { dismiss() }
                .buttonStyle(YaplyFilledButtonStyle())
                .padding(.top, 2)
        }
        .padding(20)
        .padding(.bottom, 8)
    }
}

extension View {
    func yaplyAlert(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        icon: String = "exclamationmark.circle.fill",
        buttonLabel: String = "OK"
    ) -> some View {
        yaplyPopup(isPresented: isPresented) {
            YaplyInfoView(title: title, message: message, icon: icon, buttonLabel: buttonLabel)
        }
    }
}

// MARK: - Sheet scaffold (header + scrollable body for form-style popups)

struct YaplySheetScaffold<Body: View>: View {
    let title: String
    var subtitle: String? = nil
    var primaryLabel: String? = nil
    var primaryEnabled: Bool = true
    var primaryTint: Color = .yaplyAccent
    var primaryAction: (() -> Void)? = nil
    var maxHeightFraction: CGFloat = 0.86
    @ViewBuilder var content: () -> Body

    @Environment(\.yaplyPopupDismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.yaplyTint)
                        .clipShape(Circle())
                }

                Spacer()

                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }

                Spacer()

                if let primaryLabel, let primaryAction {
                    Button(primaryLabel) { primaryAction() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryEnabled ? primaryTint : Color.yaplySecondary.opacity(0.5))
                        .disabled(!primaryEnabled)
                } else {
                    Color.clear.frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.yaplyBorder).frame(height: 1)
            }

            ScrollView {
                content()
                    .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: UIScreen.main.bounds.height * maxHeightFraction)
    }
}

// MARK: - Form field helpers

/// A labelled input group matching the web app's form rows: a small
/// caption above a bordered field.
struct YaplyLabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.yaplySecondary)
                .tracking(0.6)
            field()
        }
    }
}

extension View {
    /// Web-styled text-field chrome: tinted fill, hairline border, rounded.
    func yaplyInputStyle() -> some View {
        self
            .font(.system(size: 15))
            .foregroundStyle(Color.yaplyPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.yaplyTint)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.yaplyBorder, lineWidth: 1)
            )
    }
}

// MARK: - Button styles

struct YaplyFilledButtonStyle: ButtonStyle {
    var tint: Color = .yaplyAccent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct YaplyOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.yaplyPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.yaplyTint.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.yaplyBorder, lineWidth: 1)
            )
    }
}

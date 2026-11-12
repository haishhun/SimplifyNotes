import SwiftUI

/// One row of a `PopoverMenuButton`.
struct PopoverMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    var isOn: Bool?
    /// True when the action presents a sheet, alert or picker. Those must wait until the
    /// popover has closed (iPadOS can't present while it's dismissing); everything else runs instantly.
    var presentsScreen: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, isOn: Bool? = nil,
         presentsScreen: Bool = false, action: @escaping () -> Void) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isOn = isOn
        self.presentsScreen = presentsScreen
        self.action = action
    }
}

/// A button that shows its actions in a popover.
///
/// Used instead of `Menu` in the editor: the editor's toolbar is rebuilt whenever editor
/// state changes (autosave, thumbnails, handwriting indexing), and a `Menu` that is open
/// while that happens loses its actions, so taps on items do nothing. A popover is
/// owned by this view's state and is unaffected.
struct PopoverMenuButton<Label: View>: View {
    let items: () -> [PopoverMenuItem]
    @ViewBuilder var label: Label

    @State private var isPresented = false

    /// Time for the popover's closing animation; presenting a sheet earlier fails on iPad.
    /// (Waiting for the popover's `onDisappear` instead measured ~1.4 s — far too slow.)
    private static var presentationDelay: Duration { .milliseconds(350) }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label
        }
        .popover(isPresented: $isPresented) {
            PopoverMenuList(items: items()) { item in
                isPresented = false
                if item.presentsScreen {
                    Task { @MainActor in
                        try? await Task.sleep(for: Self.presentationDelay)
                        item.action()
                    }
                } else {
                    item.action()
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct PopoverMenuList: View {
    let items: [PopoverMenuItem]
    let select: (PopoverMenuItem) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                Button(role: item.role) {
                    select(item)
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: item.systemImage)
                            .frame(width: 24)
                        Text(item.title)
                        Spacer(minLength: Theme.Spacing.l)
                        if item.isOn == true {
                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(item.role == .destructive ? Color.red : Color.primary)
                    .padding(.horizontal, Theme.Spacing.l)
                    .frame(minHeight: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.isOn == true ? .isSelected : [])
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minWidth: 260)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .onAppear {
            withAnimation(.spring(duration: 0.28, bounce: 0.18)) { appeared = true }
        }
    }
}

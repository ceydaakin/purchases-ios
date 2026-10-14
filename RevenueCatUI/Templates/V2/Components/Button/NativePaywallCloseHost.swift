//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//

@_spi(Internal) import RevenueCat
import SwiftUI

#if !os(tvOS)

@MainActor
private func performNativePaywallAction(_ action: () async throws -> Void) async {
    do {
        try await action()
    } catch {
        Logger.error(Strings.paywall_native_navigation_action_failed(error))
    }
}

/// A single host renders native Back and Close. Components contribute their existing actions only.
@available(iOS 15.0, macOS 12.0, watchOS 8.0, *)
struct NativePaywallCloseHost: ViewModifier {
    static let closeIdentifier = "RevenueCat.NativePaywallClose"
    static let backIdentifier = "RevenueCat.NativePaywallBack"
    var enabled = true
    #if os(iOS)
    var uiKitOwner: NativePaywallUIKitOwner?
    #endif
    @StateObject private var coordinator = NativePaywallCloseCoordinator()

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if let owner = self.uiKitOwner {
            self.surface(content)
                .onReceive(self.coordinator.$actions) { owner.install($0) }
                .onDisappear { owner.removeClose() }
        } else {
            self.surface(content)
                .navigationBarBackButtonHidden(self.coordinator.action(for: .back) != nil)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NativePaywallToolbarClose(coordinator: self.coordinator, primary: true)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NativePaywallToolbarClose(coordinator: self.coordinator, primary: false)
                    }
                }
        }
        #else
        content
        #endif
    }

    private func surface(_ content: Content) -> some View {
        VStack(spacing: 0) { content }
            .environment(\.nativePaywallCloseCoordinator, self.enabled ? self.coordinator : nil)
    }

}

#if os(iOS)
@available(iOS 15.0, *)
private struct NativePaywallToolbarClose: View {
    @ObservedObject var coordinator: NativePaywallCloseCoordinator
    let primary: Bool

    @ViewBuilder var body: some View {
        if self.primary {
            if let back = self.coordinator.action(for: .back) {
                Button {
                    Task { await performNativePaywallAction { try await self.coordinator.performAction(id: back.id) } }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(back.label)
                .accessibilityIdentifier(NativePaywallCloseHost.backIdentifier)
                .disabled(!back.isEnabled)
            }
        } else if let close = self.coordinator.action(for: .close) {
            self.closeButton(close).disabled(!close.isEnabled)
        }
    }

    @ViewBuilder private func closeButton(_ action: NativePaywallCloseCoordinator.CloseAction) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button(role: .close) {
                Task { await performNativePaywallAction { try await self.coordinator.performAction(id: action.id) } }
            }
                .accessibilityLabel(action.label)
                .accessibilityIdentifier(NativePaywallCloseHost.closeIdentifier)
        } else {
            self.legacyCloseButton(action)
        }
        #else
        self.legacyCloseButton(action)
        #endif
    }

    private func legacyCloseButton(_ action: NativePaywallCloseCoordinator.CloseAction) -> some View {
        Button {
            Task { await performNativePaywallAction { try await self.coordinator.performAction(id: action.id) } }
        } label: { Image(systemName: "xmark") }
            .accessibilityLabel(action.label)
            .accessibilityIdentifier(NativePaywallCloseHost.closeIdentifier)
    }
}
#endif

#if os(iOS)
/// Passed by PaywallViewController. Never discovers or observes SwiftUI's private controllers.
@available(iOS 15.0, *)
@MainActor
final class NativePaywallUIKitOwner: NSObject, ObservableObject {
    static let closeIdentifier = NativePaywallCloseHost.closeIdentifier
    static let backIdentifier = NativePaywallCloseHost.backIdentifier
    weak var controller: UIViewController?
    @Published private var isStandalone: Bool?
    var context: NativePaywallNavigationContext? {
        self.isStandalone.map { $0 ? .standalone : .uiKit(self) }
    }
    private var items: [UIBarButtonItem] = []
    private var backAction: NativePaywallCloseCoordinator.CloseAction?
    private var closeAction: NativePaywallCloseCoordinator.CloseAction?

    func prepare(controller: UIViewController) {
        self.controller = controller
        let isStandalone = controller.parent == nil && controller.navigationController == nil
        guard self.isStandalone != isStandalone else { return }
        self.isStandalone = isStandalone
    }

    func install(_ action: NativePaywallCloseCoordinator.CloseAction?) {
        self.install(action.map { [$0] } ?? [])
    }

    func install(_ actions: [NativePaywallCloseCoordinator.CloseAction]) {
        self.removeClose()
        guard let controller = self.controller else { return }
        let back = actions.first { $0.role == .back }
        let close = actions.first { $0.role == .close && $0.isWorkflowClose }
            ?? actions.first { $0.role == .close }
        if let back {
            self.backAction = back
            let item = UIBarButtonItem(
                image: UIImage(systemName: "chevron.backward"), style: .plain,
                target: self, action: #selector(self.backTapped)
            )
            item.accessibilityIdentifier = Self.backIdentifier
            item.accessibilityLabel = back.label
            item.isEnabled = back.isEnabled
            controller.navigationItem.leftBarButtonItems =
                (controller.navigationItem.leftBarButtonItems ?? []) + [item]
            self.items.append(item)
        }
        if let close {
            self.closeAction = close
            let item = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.closeTapped))
            item.accessibilityIdentifier = Self.closeIdentifier
            item.accessibilityLabel = close.label
            item.isEnabled = close.isEnabled
            controller.navigationItem.rightBarButtonItems =
                (controller.navigationItem.rightBarButtonItems ?? []) + [item]
            self.items.append(item)
        }
    }

    @objc private func backTapped() {
        guard let action = self.backAction else { return }
        Task {
            guard self.backAction?.id == action.id, self.backAction?.isEnabled == true else { return }
            await performNativePaywallAction(action.perform)
        }
    }

    @objc private func closeTapped() {
        guard let action = self.closeAction else { return }
        Task {
            guard self.closeAction?.id == action.id, self.closeAction?.isEnabled == true else { return }
            await performNativePaywallAction(action.perform)
        }
    }

    func removeClose() {
        self.controller?.navigationItem.leftBarButtonItems = self.controller?.navigationItem.leftBarButtonItems?
            .filter { item in !self.items.contains { $0 === item } }
        self.controller?.navigationItem.rightBarButtonItems = self.controller?.navigationItem.rightBarButtonItems?
            .filter { item in !self.items.contains { $0 === item } }
        self.items = []
        self.backAction = nil
        self.closeAction = nil
    }

}
#endif

#endif

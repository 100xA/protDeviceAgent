import Foundation
import UIKit
import SafariServices
import ObjectiveC

@MainActor
final class UIPresentationCoordinator: NSObject {
    static let shared = UIPresentationCoordinator()

    private override init() {}

    func presentSafariAwaitable(url: URL) async -> Bool {
        if let presenter = topViewController() {
            // small delay to avoid overlapping with previous dismissals
            try? await Task.sleep(nanoseconds: 30_000_000)
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let safari = SFSafariViewController(url: url)
                let delegate = SafariDelegate { cont.resume(returning: true) }
                safari.delegate = delegate
                // retain delegate for lifecycle of the controller
                objc_setAssociatedObject(safari, Unmanaged.passUnretained(self).toOpaque(), delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                safari.modalPresentationStyle = .formSheet
                presenter.present(safari, animated: true)
            }
        } else {
            await UIApplication.shared.open(url)
            return true
        }
    }

    func presentShareSheetAwaitable(items: [Any]) async -> Bool {
        guard let presenter = topViewController() else { return false }
        try? await Task.sleep(nanoseconds: 30_000_000)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = presenter.view
            activity.completionWithItemsHandler = { _, _, _, _ in
                cont.resume(returning: true)
            }
            presenter.present(activity, animated: true)
        }
    }

    private func topViewController(base: UIViewController? = {
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return keyWindow.rootViewController
        }
        return UIApplication.shared.windows.first?.rootViewController
    }()) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

private final class SafariDelegate: NSObject, SFSafariViewControllerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true) { self.onFinish() }
    }
}



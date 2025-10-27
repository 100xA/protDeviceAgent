import Foundation
import CoreLocation
import UIKit
import MessageUI
import SafariServices
import Contacts

@MainActor
final class ToolExecutor: NSObject, ObservableObject, CLLocationManagerDelegate, MFMessageComposeViewControllerDelegate, SFSafariViewControllerDelegate {
    private let llm: LLMInference
    private var locationContinuation: CheckedContinuation<(CLLocationCoordinate2D, Double)?, Never>?
    private var locationManager: CLLocationManager?
    private var locationTimeoutTask: Task<Void, Never>?
    private var safariContinuation: CheckedContinuation<Bool, Never>?
    private var presentedSafari: SFSafariViewController?
    private var presentedActivity: UIActivityViewController?
    var logger: AppLogger?

    init(llm: LLMInference) {
        self.llm = llm
    }

    private func logMetrics(tool: String, start sw: Stopwatch, memBefore: UInt64, thermalBefore: ThermalState, success: Bool) {
        logger?.log(.info, "tool", tool, context: [
            "duration_ms": String(sw.elapsedMs()),
            "rss_before": formatBytes(memBefore),
            "rss_after": formatBytes(currentResidentMemoryBytes()),
            "thermal_before": thermalBefore.rawValue,
            "thermal_after": ThermalState.current().rawValue,
            "success": success ? "true" : "false"
        ])
    }

    func execute(name: String, parameters: [String: AnyCodable]) async -> ToolResult {
        let sw = Stopwatch()
        let memBefore = currentResidentMemoryBytes()
        let thermalBefore = ThermalState.current()
        let callId = UUID().uuidString
        switch name {
        case "produce_text":
            let prompt = (parameters["prompt"]?.value as? String) ?? ""
            let generated = await llm.generateResponse(prompt: prompt, maxTokens: 1024)
            let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackFromPrompt: String = {
                let marker = "Write a short note summarizing: "
                if let range = prompt.range(of: marker) {
                    let tail = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { return "Summary: \(tail)" }
                }
                return trimmed.isEmpty ? (prompt.isEmpty ? "Generated note" : "Summary: \(prompt)") : trimmed
            }()
            let text = trimmed.isEmpty ? fallbackFromPrompt : generated
            let result = ToolResult(
                toolCallId: callId,
                success: true,
                result: "Generated text",
                error: nil,
                artifacts: ["text": text]
            )
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: true)
            return result
        case "send_message":
            let recipient = (parameters["recipient"]?.value as? String) ?? ""
            let message = (parameters["message"]?.value as? String) ?? ""
            let ok = await presentMessageComposer(recipient: recipient, message: message)
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: ok)
            return ToolResult(toolCallId: callId, success: ok, result: ok ? "Composer presented" : "Composer unavailable", error: ok ? nil : "composer_unavailable", artifacts: nil)
        case "send_whatsapp":
            let phone = parameters["phone"]?.value as? String
            let message = (parameters["message"]?.value as? String) ?? ""
            let ok = openWhatsApp(phone: phone, message: message)
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: ok)
            return ToolResult(toolCallId: callId, success: ok, result: ok ? "Opened WhatsApp" : "Fallback opened", error: ok ? nil : "whatsapp_not_available", artifacts: nil)
        case "get_location":
            let (coord, acc) = await getCurrentLocation()
            let res = "lat: \(coord.latitude), lon: \(coord.longitude), accuracy: \(Int(acc))m"
            let success = acc > 0
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: success)
            return ToolResult(
                toolCallId: callId,
                success: success,
                result: res,
                error: success ? nil : "location_unavailable",
                artifacts: [
                    "latitude": "\(coord.latitude)",
                    "longitude": "\(coord.longitude)",
                    "accuracy_m": "\(Int(acc))"
                ]
            )
        case "open_url":
            var urlString = (parameters["urlString"]?.value as? String) ?? ""
            urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
                urlString = "https://" + urlString
            }
            if let url = URL(string: urlString) {
                let ok = await UIPresentationCoordinator.shared.presentSafariAwaitable(url: url)
                logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: ok)
                return ToolResult(toolCallId: callId, success: ok, result: ok ? "Opened URL" : "Failed to open URL", error: ok ? nil : "invalid_url", artifacts: nil)
            } else {
                logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: false)
                return ToolResult(toolCallId: callId, success: false, result: "Invalid URL", error: "invalid_url", artifacts: nil)
            }
        case "share_content":
            let text = (parameters["text"]?.value as? String) ?? ""
            let ok = await UIPresentationCoordinator.shared.presentShareSheetAwaitable(items: [text])
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: ok)
            return ToolResult(toolCallId: callId, success: ok, result: ok ? "Share sheet opened" : "Share failed", error: ok ? nil : "share_failed", artifacts: nil)
        case "take_screenshot":
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: true)
            return ToolResult(toolCallId: callId, success: true, result: "Screenshot instruction provided", error: nil, artifacts: ["manual_instruction": "Press Side + Volume Up to capture system-wide"]) 
        case "wait":
            let secs = (parameters["seconds"]?.value as? Int) ?? 2
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: true)
            return ToolResult(toolCallId: callId, success: true, result: "Waited \(secs)s", error: nil, artifacts: nil)
        case "search_web":
            let query = (parameters["query"]?.value as? String) ?? ""
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://www.google.com/search?q=\(q)") {
                let ok = await UIPresentationCoordinator.shared.presentSafariAwaitable(url: url)
                logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: ok)
                return ToolResult(toolCallId: callId, success: ok, result: ok ? "Opened search" : "Search failed", error: ok ? nil : "search_failed", artifacts: nil)
            } else {
                logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: false)
                return ToolResult(toolCallId: callId, success: false, result: "Search failed", error: "invalid_query", artifacts: nil)
            }
        default:
            logMetrics(tool: name, start: sw, memBefore: memBefore, thermalBefore: thermalBefore, success: false)
            return ToolResult(toolCallId: callId, success: false, result: "Unknown tool", error: "unknown_tool", artifacts: nil)
        }
    }

    private func presentMessageComposer(recipient: String, message: String) async -> Bool {
        guard MFMessageComposeViewController.canSendText() else { return false }
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.body = message
        if !recipient.isEmpty {
            let resolved = await lookupRecipients(recipient)
            if !resolved.isEmpty {
                composer.recipients = resolved
            }
        }
        guard let presenter = topViewController() else { return false }
        presenter.present(composer, animated: true)
        return true
    }

    private func lookupRecipients(_ raw: String) async -> [String] {
        if raw.rangeOfCharacter(from: .decimalDigits) != nil {
            return [normalizePhone(raw)]
        }
        guard await requestContactsAccess() else { return [] }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingName: raw)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys), !contacts.isEmpty else {
            return []
        }
        let lowered = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let sorted = contacts.sorted { a, b in
            score(contact: a, query: lowered) > score(contact: b, query: lowered)
        }
        for c in sorted {
            let phones = bestPhoneNumbers(for: c)
            if !phones.isEmpty { return phones }
        }
        return []
    }

    private func score(contact: CNContact, query: String) -> Int {
        let name = "\(contact.givenName) \(contact.familyName) \(contact.nickname) \(contact.organizationName)"
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if name == query { return 100 }
        if name.contains(query) { return 60 }
        return 10
    }

    private func bestPhoneNumbers(for contact: CNContact) -> [String] {
        let prioritized = contact.phoneNumbers.sorted { a, b in
            labelScore(a.label) > labelScore(b.label)
        }
        return prioritized.map { normalizePhone($0.value.stringValue) }.filter { !$0.isEmpty }
    }

    private func labelScore(_ label: String?) -> Int {
        guard let label else { return 0 }
        if label.localizedCaseInsensitiveContains("mobile") { return 4 }
        if label.localizedCaseInsensitiveContains("iPhone") { return 3 }
        if label.localizedCaseInsensitiveContains("main") { return 2 }
        if label.localizedCaseInsensitiveContains("home") { return 1 }
        return 0
    }

    private func normalizePhone(_ s: String) -> String {
        let filtered = s.filter { $0.isNumber || $0 == "+" }
        return String(filtered)
    }

    private func requestContactsAccess() async -> Bool {
        await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    private func presentShareSheet(text: String) -> Bool {
        guard let presenter = topViewController() else { return false }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activity, animated: true)
        return true
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

    private func openWhatsApp(phone: String?, message: String) -> Bool {
        if let phone, let url = URL(string: "whatsapp://send?phone=\(phone)&text=\(message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return true
        }
        if let url = URL(string: "https://wa.me/?text=\(message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
            presentInAppBrowser(url: url)
            return false
        }
        return false
    }

    private func openURL(urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        presentInAppBrowser(url: url)
        return true
    }

    private func presentInAppBrowser(url: URL) {
        guard let presenter = topViewController() else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .formSheet
        presenter.present(safari, animated: true)
    }

    private func presentInAppBrowserAwaitable(url: URL) async -> Bool {
        await UIPresentationCoordinator.shared.presentSafariAwaitable(url: url)
    }

    private func getCurrentLocation() async -> (CLLocationCoordinate2D, Double) {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<(CLLocationCoordinate2D, Double)?, Never>) in
            self.locationContinuation = cont
            let manager = CLLocationManager()
            self.locationManager = manager
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            case .denied, .restricted:
                cont.resume(returning: nil)
                self.cleanupLocation()
                return
            @unknown default:
                cont.resume(returning: nil)
                self.cleanupLocation()
                return
            }

            self.locationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                self.locationContinuation?.resume(returning: nil)
                self.cleanupLocation()
            }
        }

        if let result { return result }
        return (CLLocationCoordinate2D(latitude: 0, longitude: 0), 0)
    }

    private func cleanupLocation() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        locationContinuation = nil
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            locationContinuation?.resume(returning: nil)
            cleanupLocation()
        case .notDetermined:
            break
        @unknown default:
            locationContinuation?.resume(returning: nil)
            cleanupLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        locationContinuation?.resume(returning: (last.coordinate, last.horizontalAccuracy))
        cleanupLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(returning: nil)
        cleanupLocation()
    }
    
    private func presentShareSheetAwaitable(text: String) async -> Bool {
        await UIPresentationCoordinator.shared.presentShareSheetAwaitable(items: [text])
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true)
    }
}



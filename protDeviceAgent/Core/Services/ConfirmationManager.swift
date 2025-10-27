import Foundation
import SwiftUI

@MainActor
final class AlertConfirmationManager: ObservableObject {
    @Published var autoApprove: Bool = false
    @Published var pendingQuestion: (title: String, message: String, confirm: () -> Void, cancel: () -> Void)?

    func requestPlanApproval(description: String, onDecision: @escaping (Bool) -> Void) {
        if autoApprove {
            onDecision(true)
            return
        }
        pendingQuestion = (
            title: "Approve Plan?",
            message: description,
            confirm: { onDecision(true) },
            cancel: { onDecision(false) }
        )
    }

    func requestDownloadApproval(modelName: String, onDecision: @escaping (Bool) -> Void) {
        if autoApprove {
            onDecision(true)
            return
        }
        pendingQuestion = (
            title: "Download Model?",
            message: "The local model \(modelName) is required and will be downloaded.",
            confirm: { onDecision(true) },
            cancel: { onDecision(false) }
        )
    }
}




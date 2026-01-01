//
//  MessagesViewController.swift
//  Loot MessagesExtension
//
//  Created by Joshua Liu on 1/1/26.
//
import Foundation
import UIKit
import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {

    private let uiModel = LootUIModel()
    private lazy var hostingController = UIHostingController(rootView: RootContainerView(uiModel: uiModel))

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)

        // Minimal context for the UI
        let payerUUID = conversation.localParticipantIdentifier.uuidString
        let participantCount = conversation.remoteParticipantIdentifiers.count + 1

        // (Optional) clear any “deep link” state — MVP has no loading/fetching
        uiModel.currentReceipt = nil

        // Keep expansion state in sync (used by your FillReceiptView numpad)
        uiModel.isExpanded = (presentationStyle == .expanded)

        hostingController.rootView = RootContainerView(
            uiModel: uiModel,
            payerUUID: payerUUID,
            participantCount: participantCount,
            onScan:   { print("Scan tapped") },
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onCollapse: { [weak self] in self?.requestPresentationStyle(.compact) },
            onSendBill: { [weak self] receiptName, amount in
                self?.sendBillMessage(
                    receiptName: receiptName,
                    amount: amount,
                    payerUUID: payerUUID,
                    participantCount: participantCount
                )
            }
        )
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        uiModel.isExpanded = (presentationStyle == .expanded)
    }
}

// MARK: - Card render + sending (no backend, no storage)

extension MessagesViewController {

    func renderCardImage(receiptName: String,
                         displayAmount: String,
                         payerUUID: String,
                         participantCount: Int) -> UIImage {
        let card = BillCardView(
            receiptName: receiptName,
            displayAmount: displayAmount,
            payerUUID: payerUUID,
            participantCount: participantCount
        )
        .background(Color(.systemBackground))
        .padding(.top, -50)

        let hosting = UIHostingController(rootView: card)
        hosting.view.backgroundColor = .clear

        let size = CGSize(width: 250, height: 150)
        hosting.view.bounds = CGRect(origin: .zero, size: size)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            hosting.view.drawHierarchy(in: CGRect(origin: .zero, size: size),
                                       afterScreenUpdates: true)
        }
    }

    func sendBillMessage(receiptName: String,
                         amount: String,
                         payerUUID: String,
                         participantCount: Int) {
        guard let conversation = activeConversation else { return }

        // MVP: encode everything in the message URL (no DB).
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bill.example"
        components.path = "/loot"
        components.queryItems = [
            URLQueryItem(name: "title", value: receiptName),
            URLQueryItem(name: "amount", value: amount)
        ]

        let layout = MSMessageTemplateLayout()
        layout.image = renderCardImage(
            receiptName: receiptName,
            displayAmount: formattedDisplayAmount(from: amount),
            payerUUID: payerUUID,
            participantCount: participantCount
        )
        layout.caption = receiptName.isEmpty ? "New split" : receiptName

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        conversation.insert(message) { error in
            if let error { print("Error inserting message: \(error)") }
        }

        requestPresentationStyle(.compact)
    }

    private func formattedDisplayAmount(from raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "$0.00" }

        if cleaned.contains(".") {
            let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = parts.first ?? "0"
            let cents = parts.count > 1 ? String(parts[1]) : ""
            let fixed = cents.padding(toLength: 2, withPad: "0", startingAt: 0)
            return "$\(dollars).\(String(fixed.prefix(2)))"
        }
        return "$\(cleaned).00"
    }
}

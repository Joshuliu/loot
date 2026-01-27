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
    private var hasSetupRootView = false

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
        applyMessage(conversation.selectedMessage, conversation: conversation)
        setupRootView(conversation: conversation)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        uiModel.isExpanded = (presentationStyle == .expanded)
    }
    
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        // Use the message parameter directly, not conversation.selectedMessage
        applyMessage(message, conversation: conversation)
    }
}

// MARK: - Card render + sending (no backend, no storage)

extension MessagesViewController {

    private func applyMessage(_ message: MSMessage?, conversation: MSConversation) {
        // expansion state
        uiModel.isExpanded = (presentationStyle == .expanded)

        if let msg = message,
           let url = msg.url,
           let payload = LootMessageCodec.payload(from: url) {

            uiModel.openedMessagePayload = payload
            uiModel.currentReceipt = payload.toReceiptDisplay()
            uiModel.currentScreen = .messageViewer
        }
        // Don't clear openedMessagePayload when message is deselected -
        // the user is still viewing it. Only clear when they explicitly close.
    }

    private func setupRootView(conversation: MSConversation) {
        let participantCount = conversation.remoteParticipantIdentifiers.count + 1

        hostingController.rootView = RootContainerView(
            uiModel: uiModel,
            participantCount: participantCount,
            onScan:   { print("Scan tapped") },
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onCollapse: { [weak self] in self?.requestPresentationStyle(.compact) },
            onSendBill: { [weak self] receiptName, amount in
                self?.sendBillMessage(
                    receiptName: receiptName,
                    amount: amount,
                    participantCount: participantCount
                )
            }
        )
    }
    
    func renderCardImage(receiptName: String,
                         displayAmount: String,
                         participantCount: Int,
                         splitPayload: SplitPayload) -> UIImage {
        
        // Extract owed amounts for ring display (only included guests)
        let activeGuests = splitPayload.g.indices.filter { splitPayload.g[$0].inc }
        let owedAmounts: [Int] = activeGuests.map { idx in
            splitPayload.o.indices.contains(idx) ? max(0, splitPayload.o[idx]) : 0
        }
        
        let card = BillCardView(
            receiptName: receiptName,
            displayAmount: displayAmount,
            displayName: myDisplayNameFromDefaults(),
            splitLabel: splitLabelFromMode(splitPayload.m),
            owedAmounts: owedAmounts.isEmpty ? nil : owedAmounts,  // Only pass if non-empty
            totalCents: splitPayload.tot
        )

        let hosting = UIHostingController(rootView: card)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []  // Remove safe area insets that cause offset

        let size = CGSize(width: 250, height: 150)
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds,
                                       afterScreenUpdates: true)
        }
    }
    
    private func splitLabelFromMode(_ mode: SplitPayload.Mode) -> String {
        switch mode {
        case .byItems: return "Split by items"
        case .custom: return "Custom split"
        case .equally: return "Split evenly"
        }
    }

    func sendBillMessage(receiptName: String,
                         amount: String,
                         participantCount: Int) {
        guard let conversation = activeConversation else { return }

        // Base URL (keep your current structure)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bill.example"
        components.path = "/loot"

        // Build a "portable" receipt + split payload
        let fallbackTotalCents = centsFromAmountString(amount)
        let receiptDisplay = uiModel.currentReceipt ?? ReceiptDisplay(
            id: UUID().uuidString,
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: fallbackTotalCents,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 0,
            totalCents: fallbackTotalCents,
            items: []
        )

        let draft = uiModel.currentSplitDraft
        let splitPayload = SplitPayload.from(draft: draft,
                                             participantCount: participantCount,
                                             totalCents: receiptDisplay.totalCents)

        let receiptPayload = ReceiptPayload.from(receipt: receiptDisplay, split: splitPayload)

        let payload = LootMessagePayload(r: receiptPayload, s: splitPayload)

        // Put legacy fields too (nice for debugging / older messages)
        components.queryItems = [
            URLQueryItem(name: "title", value: receiptDisplay.title),
            URLQueryItem(name: "amount", value: formattedDisplayAmount(from: amount))
        ]
        LootMessageCodec.writePayload(into: &components, payload: payload)

        let layout = MSMessageTemplateLayout()
        layout.image = renderCardImage(
            receiptName: receiptDisplay.title,
            displayAmount: ReceiptDisplay.money(receiptDisplay.totalCents),
            participantCount: participantCount,
            splitPayload: splitPayload
        )

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

private func centsFromAmountString(_ raw: String) -> Int {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: ",", with: "")
    guard !s.isEmpty else { return 0 }
    if s.contains(".") {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let dollars = Int(parts.first ?? "0") ?? 0
        let centsRaw = parts.count > 1 ? String(parts[1]) : ""
        let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
        let cents = Int(String(cents2.prefix(2))) ?? 0
        return max(0, dollars * 100 + cents)
    }
    return max(0, (Int(s) ?? 0) * 100)
}

// MARK: - Payload -> ReceiptDisplay (✅ UPDATED for new field names)

private extension LootMessagePayload {
    func toReceiptDisplay() -> ReceiptDisplay {
        let receiptData = r
        let splitData = s
        
        let items: [ReceiptDisplay.Item] = receiptData.i.map { it in
            let responsible: [ReceiptDisplay.Responsible] = it.rs.map { slot in
                let nm: String = {
                    guard splitData.g.indices.contains(slot) else { return "Guest \(slot + 1)" }
                    let g = splitData.g[slot]
                    let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    return g.me ? "Me" : "Guest \(slot + 1)"
                }()
                return ReceiptDisplay.Responsible(slotIndex: slot, displayName: nm)
            }
            .sorted(by: { $0.slotIndex < $1.slotIndex })

            return ReceiptDisplay.Item(
                id: it.id,
                label: it.l,
                priceCents: it.p,
                responsible: responsible
            )
        }

        return ReceiptDisplay(
            id: receiptData.id,
            title: receiptData.t,
            createdAt: Date(timeIntervalSince1970: receiptData.c),
            subtotalCents: receiptData.sub,
            feesCents: receiptData.f,
            taxCents: receiptData.tx,
            tipCents: receiptData.tip,
            discountCents: receiptData.d,
            totalCents: receiptData.tot,
            items: items
        )
    }
}

// MARK: - Build SplitPayload / ReceiptPayload

private extension SplitPayload {
    static func from(draft: SplitDraft?, participantCount: Int, totalCents: Int) -> SplitPayload {
        // Seed guests if no draft
        let guests: [Guest] = {
            if let d = draft, !d.guests.isEmpty {
                return d.guests.map { Guest(n: $0.name, inc: $0.isIncluded, me: $0.isMe) }
            }
            // default: me + N-1 unnamed
            var out: [Guest] = [Guest(n: myDisplayNameFromDefaults(), inc: true, me: true)]
            if participantCount > 1 {
                for _ in 1..<participantCount {
                    out.append(Guest(n: "", inc: true, me: false))
                }
            }
            return out
        }()

        let payerIndex: Int = {
            guard let d = draft else { return 0 }
            return d.guests.firstIndex(where: { $0.id == d.payerGuestId }) ?? 0
        }()

        let mode: Mode = {
            guard let d = draft else { return .equally }
            switch d.mode {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        let fees = draft?.feesCents ?? 0
        let tax = draft?.taxCents ?? 0
        let tip = draft?.tipCents ?? 0
        let discount = draft?.discountCents ?? 0

        // ✅ Convert draft items to tuples for SplitMath (no longer creating SplitPayload.Item array)
        let itemsForMath: [(label: String, priceCents: Int, assignedSlots: [Int])] = {
            guard let d = draft, d.mode == .byItems else { return [] }
            let slotIndexByUUID: [UUID: Int] = Dictionary(uniqueKeysWithValues:
                d.guests.enumerated().map { ($0.element.id, $0.offset) })
            return d.items.map { it in
                let slots = it.assignedGuestIds.compactMap { slotIndexByUUID[$0] }.sorted()
                return (label: it.label, priceCents: it.priceCents, assignedSlots: slots)
            }
        }()

        // Compute owed (always) and force sum to total by adjusting payer
        let owed = SplitMath.computeOwedCents(
            mode: mode,
            guests: guests,
            payerIndex: payerIndex,
            totalCents: totalCents,
            perGuestActive: draft?.perGuestCents,
            items: itemsForMath,
            feesCents: fees,
            taxCents: tax,
            tipCents: tip,
            discountCents: discount
        )

        return SplitPayload(
            m: mode,
            g: guests,
            pi: payerIndex,
            o: owed,
            f: fees == 0 ? nil : fees,
            tx: tax == 0 ? nil : tax,
            tip: tip == 0 ? nil : tip,
            d: discount == 0 ? nil : discount,
            tot: totalCents
        )
    }
}

private extension ReceiptPayload {
    static func from(receipt: ReceiptDisplay, split: SplitPayload) -> ReceiptPayload {
        let isByItems = (split.m == .byItems)

        let items: [ReceiptItemPayload] = {
            // ✅ Always use receipt items, add assignments for by-items mode
            return receipt.items.map { it in
                let slots = isByItems ? it.responsible.map { $0.slotIndex }.sorted() : []
                return ReceiptItemPayload(
                    id: it.id,
                    l: it.label,
                    p: it.priceCents,
                    rs: slots
                )
            }
        }()

        return ReceiptPayload(
            id: receipt.id,
            t: receipt.title,
            c: receipt.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            sub: receipt.subtotalCents,
            f: receipt.feesCents,
            tx: receipt.taxCents,
            tip: receipt.tipCents,
            d: receipt.discountCents,
            tot: receipt.totalCents,
            i: items
        )
    }
}

// MARK: - Math (equal/custom/by-items) with stable cents (✅ UPDATED signature)

private enum SplitMath {
    static func computeOwedCents(
        mode: SplitPayload.Mode,
        guests: [SplitPayload.Guest],
        payerIndex: Int,
        totalCents: Int,
        perGuestActive: [Int]?,
        items: [(label: String, priceCents: Int, assignedSlots: [Int])],  // ✅ Changed from [SplitPayload.Item]
        feesCents: Int,
        taxCents: Int,
        tipCents: Int,
        discountCents: Int
    ) -> [Int] {

        let included = guests.indices.filter { guests[$0].inc }  // ✅ Changed from .included
        guard !included.isEmpty else { return Array(repeating: 0, count: guests.count) }

        let safePayer = included.contains(payerIndex) ? payerIndex : (included.first ?? 0)

        func clampToTotal(_ owed: inout [Int]) {
            var sum = owed.reduce(0, +)
            let diff = totalCents - sum
            if diff != 0, owed.indices.contains(safePayer) {
                owed[safePayer] = max(0, owed[safePayer] + diff)
                sum = owed.reduce(0, +)
            }
            // still mismatched? (shouldn't happen, but keep safe)
            if sum != totalCents, let first = included.first {
                owed[first] = max(0, owed[first] + (totalCents - sum))
            }
        }

        // Start with all zeros for full guest list
        var owed = Array(repeating: 0, count: guests.count)

        switch mode {
        case .equally:
            let shares = splitEvenly(total: totalCents, count: included.count)
            for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            clampToTotal(&owed)
            return owed

        case .custom:
            // custom comes as active-only in your app; map in order of included guests
            if let perGuestActive, perGuestActive.count == included.count {
                for (i, idx) in included.enumerated() { owed[idx] = max(0, perGuestActive[i]) }
            } else {
                let shares = splitEvenly(total: totalCents, count: included.count)
                for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            }
            clampToTotal(&owed)
            return owed

        case .byItems:
            // 1) subtotal from items (split shared items evenly among assigned)
            var subtotals = Array(repeating: 0, count: guests.count)

            for it in items {
                let assigned = it.assignedSlots.filter { guests.indices.contains($0) && guests[$0].inc }
                let targets = assigned.isEmpty ? [safePayer] : assigned.sorted()
                let parts = splitEvenly(total: max(0, it.priceCents), count: targets.count)
                for (i, gidx) in targets.enumerated() { subtotals[gidx] += parts[i] }
            }

            // 2) allocate extras (fees+tax+tip-discount) proportional to subtotal (or evenly if subtotal=0)
            let extras = max(0, feesCents) + max(0, taxCents) + max(0, tipCents) - max(0, discountCents)
            let extrasAlloc = allocateProportional(total: extras, base: subtotals, included: included)

            for idx in included {
                owed[idx] = max(0, subtotals[idx] + extrasAlloc[idx])
            }

            clampToTotal(&owed)
            return owed
        }
    }

    private static func splitEvenly(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }

    private static func allocateProportional(total: Int, base: [Int], included: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: base.count)
        guard total != 0 else { return out }

        let sumBase = included.reduce(0) { $0 + max(0, base[$1]) }
        if sumBase <= 0 {
            // evenly across included
            let shares = splitEvenly(total: total, count: included.count)
            for (i, idx) in included.enumerated() { out[idx] = shares[i] }
            return out
        }

        // proportional with remainder distribution by fractional part
        var floors: [Int] = []
        var fracs: [(idx: Int, frac: Double)] = []

        var used = 0
        for idx in included {
            let b = Double(max(0, base[idx]))
            let raw = (Double(total) * b) / Double(sumBase)
            let f = Int(floor(raw))
            floors.append(f)
            used += f
            fracs.append((idx: idx, frac: raw - Double(f)))
        }

        for (i, idx) in included.enumerated() {
            out[idx] = floors[i]
        }

        var rem = total - used
        if rem > 0 {
            fracs.sort { $0.frac > $1.frac }
            var j = 0
            while rem > 0 && !fracs.isEmpty {
                out[fracs[j % fracs.count].idx] += 1
                rem -= 1
                j += 1
            }
        }
        return out
    }
}

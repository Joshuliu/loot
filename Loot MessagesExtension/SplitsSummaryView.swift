//
//  SplitsSummaryView.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI

struct SplitsSummaryView: View {
    @ObservedObject var uiModel: LootUIModel
    @State private var split: SplitPayload
    let items: [ReceiptItemPayload]  // Receipt items with responsibleSlots

    @State private var selectedIndex: Int = 0
    @State private var needsSlotClaim: Bool = false
    @State private var hasClaimed: Bool = false

    init(uiModel: LootUIModel, split: SplitPayload, items: [ReceiptItemPayload]) {
        self.uiModel = uiModel
        self._split = State(initialValue: split)
        self.items = items
    }

    private var includedIndices: [Int] {
        split.g.indices.filter { split.o.indices.contains($0) && split.o[$0] > 0 }
    }

    private var safeTotal: Int {
        max(0, split.tot)
    }

    private func displayName(for idx: Int) -> String {
        let g = split.g[idx]
        let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if g.uid == KeychainHelper.getOrCreateUserId() { return "Me" }
        return "Guest \(idx + 1)"
    }

    private func owed(for idx: Int) -> Int {
        guard split.o.indices.contains(idx) else { return 0 }
        return max(0, split.o[idx])
    }

    private func percentText(_ cents: Int) -> String {
        guard safeTotal > 0 else { return "0%" }
        let p = (Double(cents) / Double(safeTotal)) * 100
        return String(format: "%.0f%%", p)
    }

    // Use shared BadgeColors
    private func colorForSlot(_ i: Int) -> Color {
        BadgeColors.color(for: i)
    }

    // Get items assigned to a specific guest slot (for byItems mode)
    private func itemsForSlot(_ slotIndex: Int) -> [ReceiptItemPayload] {
        items.filter { $0.rs.contains(slotIndex) }
    }

    private func sumBeforeIncludedSlot(_ includedSlot: Int) -> Int {
        guard includedSlot > 0 else { return 0 }
        let prev = includedIndices.prefix(includedSlot)
        return prev.reduce(0) { $0 + owed(for: $1) }
    }

    private func sumThroughIncludedSlot(_ includedSlot: Int) -> Int {
        let upTo = includedIndices.prefix(includedSlot + 1)
        return upTo.reduce(0) { $0 + owed(for: $1) }
    }

    private func lastActiveIndex(idx: Int) -> Int {
        for j in stride(from: idx - 1, through: 0, by: -1) {
            if includedIndices[j] > 0 {
                return j
            }
        }
        return 0
    }

    // MARK: - Slot claim helpers

    private func claimSlot(at guestIndex: Int) {
        let myUid = KeychainHelper.getOrCreateUserId()
        split.g[guestIndex].uid = myUid
        split.g[guestIndex].n = myDisplayNameFromDefaults()
        hasClaimed = true
        needsSlotClaim = false
        persistClaim()
    }

    private func persistClaim() {
        guard var payload = uiModel.openedMessagePayload,
              let docId = uiModel.openedMessageDocId else { return }

        payload.s = split
        uiModel.openedMessagePayload = payload

        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[SplitsSummaryView] Slot claim persisted to \(docId)")
            } catch {
                print("[SplitsSummaryView] Failed to persist slot claim: \(error)")
            }
        }
    }

    var body: some View {
        let included = includedIndices
        let count = included.count
        let selectedIncludedSlot = max(0, min(selectedIndex, max(0, count - 1)))
        let selectedGuestIndex = count > 0 ? included[selectedIncludedSlot] : 0
        let selectedCents = owed(for: selectedGuestIndex)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Slot-claim banner for custom / byItems
                if needsSlotClaim {
                    VStack(spacing: 6) {
                        Text("Which one are you?")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Tap your name to claim your spot")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                GeometryReader { geo in
                    let size = min(geo.size.width, 230)
                    let lineW: CGFloat = 30
                    let radius = size / 2 - lineW / 2
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let handleRadius = radius + lineW / 2
                    let dimmer = Color(white: 0.55)

                    ZStack {
                        Circle()
                            .stroke(Color(.secondarySystemBackground),
                                    style: .init(lineWidth: lineW, lineCap: .round))
                            .frame(width: size, height: size)

                        ForEach(0..<count, id: \.self) { i in
                            if safeTotal > 0 {
                                let start = Double(sumBeforeIncludedSlot(i)) / Double(safeTotal)
                                let end = Double(sumThroughIncludedSlot(i)) / Double(safeTotal)
                                if end > start {
                                    Circle()
                                        .trim(from: start, to: end)
                                        .stroke(colorForSlot(i),
                                                style: .init(lineWidth: lineW, lineCap: .round))
                                        .colorMultiply(i == selectedIndex ? .white : dimmer)
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: size, height: size)
                                }
                                let colorIdx = lastActiveIndex(idx: i)
                                if sumBeforeIncludedSlot(i) != sumThroughIncludedSlot(i) {
                                    let ang = -(.pi / 1.975) + (start * 2 * .pi)
                                    let hx = center.x + handleRadius * cos(ang)
                                    let hy = center.y + handleRadius * sin(ang)
                                    Circle()
                                        .fill(BadgeColors.color(for: colorIdx))
                                        .overlay(
                                            Circle().stroke(BadgeColors.color(for: colorIdx), lineWidth: 0.05)
                                        )
                                        .colorMultiply(colorIdx != selectedIndex ? .white : dimmer)
                                        .frame(width: lineW, height: lineW)
                                        .position(x: hx, y: hy)
                                }
                            }
                        }

                        VStack(spacing: 6) {
                            Text("\(displayName(for: selectedGuestIndex)) owes")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(ReceiptDisplay.money(selectedCents))
                                .font(.system(size: 34, weight: .bold))

                            Text(percentText(selectedCents))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 240)

                // Guest list
                VStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { i in
                        let gi = included[i]
                        // Get items for this guest slot
                        let guestItems = itemsForSlot(i)
                        let isUnclaimed = split.g[gi].uid == nil

                        Button {
                            if needsSlotClaim && isUnclaimed {
                                claimSlot(at: gi)
                            }
                            selectedIndex = i
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    ColoredCircleBadge(
                                        text: BadgeColors.initials(from: displayName(for: gi), fallback: gi),
                                        color: colorForSlot(i)
                                    )

                                    Text(displayName(for: gi))
                                        .font(.system(size: 15, weight: i == selectedIndex ? .semibold : .regular))

                                    if split.pi == i {
                                        Text("Payer")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    }

                                    Spacer()

                                    Text(ReceiptDisplay.money(owed(for: gi)))
                                        .font(.system(size: 15, weight: .semibold))
                                }

                                // Show items for this guest
                                if !guestItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(guestItems, id: \.id) { item in
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(colorForSlot(i).opacity(0.5))
                                                    .frame(width: 6, height: 6)
                                                Text(item.l)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.leading, 10)
                                    .padding(.top, 8)
                                }
                                
                                VStack {
                                    if split.pi == gi {
                                        // Payer transactions
                                        ForEach(0..<count, id: \.self) { j in
                                            if gi != j {
                                                HStack {
                                                    Text(displayName(for: j) + " → " + displayName(for: gi))
                                                        .font(.system(size: 15, weight: .semibold))
                                                    Spacer()
                                                    Text(ReceiptDisplay.money(owed(for: j)))
                                                        .font(.system(size: 15, weight: .semibold))
                                                }
                                            }
                                        }
                                    } else {
                                        HStack {
                                            Text(displayName(for: i) + " → " + displayName(for: split.pi))
                                                .font(.system(size: 15, weight: .semibold))
                                            Spacer()
                                            Text(ReceiptDisplay.money(owed(for: gi)))
                                                .font(.system(size: 15, weight: .semibold))
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(i == selectedIndex ? Color(.secondarySystemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                // Dashed border on unclaimed slots when claim is needed
                                needsSlotClaim && isUnclaimed
                                    ? RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                        .foregroundStyle(Color.blue.opacity(0.5))
                                    : nil
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 15)

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .onAppear {
            let myUid = KeychainHelper.getOrCreateUserId()
            let alreadyClaimed = split.g.contains { $0.uid == myUid }
            if !alreadyClaimed && !hasClaimed {
                if split.m == .equally, let i = split.g.firstIndex(where: { $0.uid == nil }) {
                    // Equally mode: auto-claim first free slot
                    claimSlot(at: i)
                } else if split.m != .equally {
                    let freeSlots = split.g.indices.filter { split.g[$0].uid == nil }
                    if freeSlots.count == 1 {
                        // Only one unclaimed slot — auto-claim it
                        claimSlot(at: freeSlots[0])
                    } else {
                        // Multiple unclaimed slots — show picker
                        needsSlotClaim = true
                    }
                }
            }
        }
    }
}

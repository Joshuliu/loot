//
//  SplitView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//
import SwiftUI

struct SplitDraft: Equatable {
    enum Mode: String, CaseIterable {
        case equally = "Split Equally"
        case byItems = "Split by Items"
        case custom = "Custom Split"
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        var label: String
        var priceCents: Int
        var assignedGuestIds: [UUID]
    }

    var guests: [SplitGuest]
    var payerGuestId: UUID

    var mode: Mode
    var totalCents: Int
    var perGuestCents: [Int]
    var items: [Item]
    var feesCents: Int
    var taxCents: Int
    var tipCents: Int
    var discountCents: Int

    var activeGuests: [SplitGuest] {
        guests.filter { $0.isIncluded }
    }
}

struct SplitView: View {
    @ObservedObject var uiModel: LootUIModel
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
        @State private var lastHapticCents: Int = 0
    let amountString: String
    let participantCount: Int
    let initialDraft: SplitDraft?
    let onRequestExpand: () -> Void
    let onBack: () -> Void
    let onApply: (SplitDraft) -> Void

    init(
        uiModel: LootUIModel,
        amountString: String,
        participantCount: Int,
        initialDraft: SplitDraft? = nil,
        onRequestExpand: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onApply: @escaping (SplitDraft) -> Void = { _ in }
    ) {
        self.uiModel = uiModel
        self.amountString = amountString
        self.participantCount = participantCount
        self.initialDraft = initialDraft
        self.onRequestExpand = onRequestExpand
        self.onBack = onBack
        self.onApply = onApply
    }

    // MARK: - Mode state
    @State private var mode: SplitDraft.Mode = .equally
    @State private var lastMode: SplitDraft.Mode = .equally

    // MARK: - Guests (editable)
    @State private var guests: [SplitGuest] = []
    @State private var payerGuestId: UUID = UUID()

    // Split panels use *included* guests only
    @State private var guestSelectedIndex: Int = 0
    @State private var guestAmountsCents: [Int] = []
    @State private var donutDrag: DonutDrag? = nil

    // Bottom guest editor UI
    @State private var showGuestEditor: Bool = false
    @State private var guestEditorMode: GuestEditorMode? = nil
    @State private var draftGuests: [SplitGuest] = []
    @State private var draftPayerGuestId: UUID = UUID()

    private struct DonutDrag {
        var lastRawFrac: Double
        var endFracUnwrapped: Double
    }

    // MARK: - By items state
    private struct DraftReceiptItem: Identifiable, Equatable {
        let id: UUID
        var label: String
        var price: String
        var assignedGuestIds: Set<UUID>

        var isComplete: Bool {
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @State private var byItemItems: [DraftReceiptItem] = []
    @State private var byItemSelectedGuestId: UUID = UUID()
    @State private var feesString: String = ""
    @State private var taxString: String = ""
    @State private var tipString: String = ""
    @State private var discountString: String = ""
    @State private var didInitByItem: Bool = false

    // MARK: - Derived guest views
    private var activeGuests: [SplitGuest] { guests.filter { $0.isIncluded } }
    private var activeCount: Int { max(0, activeGuests.count) }

    private func allIndex(for id: UUID) -> Int? {
        guests.firstIndex(where: { $0.id == id })
    }

    private func displayName(for guest: SplitGuest, fallbackIndexInAllGuests: Int? = nil) -> String {
        let t = guest.trimmedName
        if !t.isEmpty { return t }
        if guest.isMe {
            let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            return me.isEmpty ? "Me" : me
        }
        if let idx = fallbackIndexInAllGuests {
            return "Guest \(idx + 1)"
        }
        return "Guest"
    }

    private func payerDisplayName() -> String {
        if let idx = guests.firstIndex(where: { $0.id == payerGuestId }) {
            return displayName(for: guests[idx], fallbackIndexInAllGuests: idx)
        }
        return displayName(for: guests.first(where: { $0.isMe }) ?? SplitGuest(name: "Me", isIncluded: true, isMe: true))
    }

    // MARK: - Money helpers
    private func cleanMoney(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
    }

    private func moneyToCents(_ raw: String) -> Int {
        let s = cleanMoney(raw)
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

    private var totalCents: Int { moneyToCents(amountString) }

    // MARK: - Equal split generator (exact cents)
    private func equalSplitCents(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) {
                out[i] += 1
            }
        }
        return out
    }

    private func ensureGuestArrays() {
        let cnt = activeCount
        if guestAmountsCents.count != cnt {
            guestAmountsCents = Array(guestAmountsCents.prefix(cnt))
            if guestAmountsCents.count < cnt {
                guestAmountsCents.append(contentsOf: Array(repeating: 0, count: cnt - guestAmountsCents.count))
            }
        }
        if cnt > 0 {
            guestSelectedIndex = min(max(guestSelectedIndex, 0), cnt - 1)
        } else {
            guestSelectedIndex = 0
        }
    }

    private func sumBefore(_ idx: Int) -> Int {
        guard idx > 0, guestAmountsCents.count == activeCount else { return 0 }
        return guestAmountsCents.prefix(idx).reduce(0, +)
    }

    private func sumThrough(_ idx: Int) -> Int {
        guard guestAmountsCents.count == activeCount else { return 0 }
        return guestAmountsCents.prefix(idx + 1).reduce(0, +)
    }

    private func remainingExcluding(_ idx: Int) -> Int {
        ensureGuestArrays()
        guard !guestAmountsCents.isEmpty else { return totalCents }
        let totalAssigned = guestAmountsCents.reduce(0, +)
        let current = guestAmountsCents.indices.contains(idx) ? guestAmountsCents[idx] : 0
        return max(0, totalCents - (totalAssigned - current))
    }

    private func percentText(_ cents: Int) -> String {
        guard totalCents > 0 else { return "0%" }
        let p = (Double(cents) / Double(totalCents)) * 100
        return String(format: "%.0f%%", p)
    }

    private func moneyParts(_ cents: Int) -> (String, String) {
        let absCents = abs(cents)
        let d = absCents / 100
        let c = absCents % 100
        let sign = cents < 0 ? "-" : ""
        return ("\(sign)$\(d).", String(format: "%02d", c))
    }

    // MARK: - Palette
    private let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .mint]
    private func colorForSlot(_ i: Int) -> Color { palette[i % palette.count] }

    private func colorForGuestId(_ id: UUID) -> Color {
        guard let idx = activeGuests.firstIndex(where: { $0.id == id }) else { return palette[0] }
        return colorForSlot(idx)
    }

    private func initials(_ name: String, fallback: Int) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return String(fallback + 1) }
        let parts = t.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(t.prefix(1)).uppercased()
    }

    // MARK: - Seed By-Items from receipt used by ReceiptView
    private func seedByItemsFromReceipt() {
        didInitByItem = true

        let receiptItems = uiModel.currentReceipt?.items ?? []
        var seeded: [DraftReceiptItem] = receiptItems.map { it in
            DraftReceiptItem(
                id: UUID(),
                label: it.label,
                price: ReceiptDisplay.money(it.priceCents),
                assignedGuestIds: []
            )
        }
        seeded.append(DraftReceiptItem(id: UUID(), label: "", price: "", assignedGuestIds: []))
        byItemItems = seeded

        let r = uiModel.currentReceipt
        feesString = (r?.feesCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.feesCents ?? 0)
        taxString = (r?.taxCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.taxCents ?? 0)
        tipString = (r?.tipCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.tipCents ?? 0)
        discountString = (r?.discountCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.discountCents ?? 0)
    }

    // MARK: - Mode switching logic
    private func selectMode(_ newMode: SplitDraft.Mode) {
        lastMode = mode
        mode = newMode

        if newMode == .equally {
            ensureGuestArrays()
            guestAmountsCents = equalSplitCents(total: totalCents, count: activeCount)
        }

        if newMode == .custom {
            ensureGuestArrays()
            if lastMode == .equally {
                guestAmountsCents = Array(repeating: 0, count: activeCount)
                guestSelectedIndex = 0
            }
        }

        if newMode == .byItems {
            if !didInitByItem { seedByItemsFromReceipt() }
        }
    }

    // MARK: - Build result
    private func draft() -> SplitDraft {
        let items: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { it in
                SplitDraft.Item(
                    id: it.id,
                    label: it.label,
                    priceCents: moneyToCents(it.price),
                    assignedGuestIds: it.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }
                )
            }

        return SplitDraft(
            guests: guests,
            payerGuestId: payerGuestId,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: guestAmountsCents,
            items: items,
            feesCents: moneyToCents(feesString),
            taxCents: moneyToCents(taxString),
            tipCents: moneyToCents(tipString),
            discountCents: moneyToCents(discountString),
        )
    }

    // MARK: - UI: menu bar
    private func modeButton(_ m: SplitDraft.Mode) -> some View {
        let selected = (m == mode)
        return Button {
            selectMode(m)
        } label: {
            Text(m.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.blue : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Guest donut view (used for equally + custom)
    private func byGuestPanel(interactive: Bool, subtitle: String) -> some View {
        let selectedCents = guestAmountsCents.indices.contains(guestSelectedIndex)
            ? guestAmountsCents[guestSelectedIndex]
            : 0

        let parts = moneyParts(selectedCents)
        let remaining = max(0, totalCents - guestAmountsCents.reduce(0, +))

        return VStack(alignment: .leading, spacing: 18) {
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let size = min(geo.size.width, 210)
                let lineW: CGFloat = 30
                let radius = size / 2 - lineW / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let handleRadius = radius + lineW / 2

                ZStack {
                    Circle()
                        .stroke(Color(.secondarySystemBackground),
                                style: .init(lineWidth: lineW, lineCap: .round))
                        .frame(width: size, height: size)

                    ForEach(0..<activeCount, id: \.self) { i in
                        if totalCents > 0, guestAmountsCents.count == activeCount {
                            let startFrac = Double(sumBefore(i)) / Double(totalCents)
                            let endFrac = Double(sumThrough(i)) / Double(totalCents)
                            if endFrac > startFrac {
                                Circle()
                                    .trim(from: startFrac, to: endFrac)
                                    .stroke(colorForSlot(i),
                                            style: .init(lineWidth: lineW, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: size, height: size)
                            }
                            if i > 0 {
                                let ang = -(.pi / 1.99) + (startFrac * 2 * .pi)
                                let hx = center.x + handleRadius * cos(ang)
                                let hy = center.y + handleRadius * sin(ang)

                                Circle()
                                    .fill(colorForSlot(i - 1))
                                    .overlay(
                                            Circle().stroke(colorForSlot(i - 1), lineWidth: 0.05)
                                        )
                                    .frame(width: 30, height: 30)
                                    .position(x: hx, y: hy)
                            }
                        }
                    }

                    if totalCents > 0,
                       guestAmountsCents.count == activeCount,
                       activeCount > 0 {

                        let startFrac = Double(sumBefore(guestSelectedIndex)) / Double(totalCents)
                        let endFrac = Double(sumThrough(guestSelectedIndex)) / Double(totalCents)
                        let handleFrac = max(startFrac, endFrac)
                        let ang = (handleFrac * 2 * .pi) - (.pi / 2)

                        let hx = center.x + handleRadius * cos(ang)
                        let hy = center.y + handleRadius * sin(ang)

                        Circle()
                            .fill(colorForSlot(guestSelectedIndex))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(.white, lineWidth: 5))
                            .position(x: hx, y: hy)
                            .contentShape(Circle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard interactive else { return }
                                        guard totalCents > 0 else { return }

                                        let p = value.location
                                        let dx = p.x - center.x
                                        let dy = p.y - center.y

                                        var a = atan2(dy, dx) + (.pi / 2)
                                        if a < 0 { a += 2 * .pi }
                                        let rawFrac = a / (2 * .pi)

                                        let startFrac = Double(sumBefore(guestSelectedIndex)) / Double(totalCents)
                                        let maxAlloc = remainingExcluding(guestSelectedIndex)
                                        let maxEnd = startFrac + Double(maxAlloc) / Double(totalCents)

                                        if donutDrag == nil {
                                            let curEnd = Double(sumThrough(guestSelectedIndex)) / Double(totalCents)
                                            donutDrag = DonutDrag(lastRawFrac: rawFrac, endFracUnwrapped: curEnd)
                                            haptic.prepare()
                                        }

                                        var d = donutDrag!
                                        var delta = rawFrac - d.lastRawFrac
                                        if delta > 0.5 { delta -= 1 }
                                        if delta < -0.5 { delta += 1 }
                                        d.lastRawFrac = rawFrac
                                        d.endFracUnwrapped += delta

                                        let endClamped = min(max(d.endFracUnwrapped, startFrac), maxEnd)
                                        donutDrag = d

                                        var newCents = Int(round((endClamped - startFrac) * Double(totalCents)))
                                        newCents = min(max(newCents, 0), maxAlloc)
                                        // ✅ Add haptic feedback on significant changes
                                        let centsDiff = abs(newCents - lastHapticCents)
                                        
                                        // Tap occurs 100 times in the donut
                                        if centsDiff >= totalCents/100 {
                                            haptic.impactOccurred(intensity: 1.5)
                                            lastHapticCents = newCents
                                            haptic.prepare()
                                        }
                                        
                                        guestAmountsCents[guestSelectedIndex] = newCents
                                    }
                                    .onEnded { _ in donutDrag = nil }
                            )
                            .animation(nil, value: handleFrac)
                            .opacity(mode == .equally ? 0 : 1)
                    }

                    VStack(spacing: 4) {
                        let g = activeGuests.indices.contains(guestSelectedIndex) ? activeGuests[guestSelectedIndex] : nil
                        let nm = g.map { displayName(for: $0, fallbackIndexInAllGuests: allIndex(for: $0.id)) } ?? "Guest"
                        Text("\(nm) pays")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(parts.0)
                                .font(.system(size: 30, weight: .bold))
                            Text(parts.1)
                                .font(.system(size: 30, weight: .bold))
                        }

                        Text(percentText(selectedCents))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 220)

            VStack(spacing: 10) {
                ForEach(0..<activeCount, id: \.self) { i in
                    Button {
                        guard interactive else { return }
                        guestSelectedIndex = i
                    } label: {
                        HStack {
                            ColoredCircleBadge(
                                text: initials(displayName(for: activeGuests[i], fallbackIndexInAllGuests: allIndex(for: activeGuests[i].id)), fallback: i),
                                color: colorForSlot(i)
                            )

                            Text(displayName(for: activeGuests[i], fallbackIndexInAllGuests: allIndex(for: activeGuests[i].id)))
                                .font(.system(size: 15, weight: i == guestSelectedIndex ? .semibold : .regular))
                            Spacer()
                            Text(ReceiptDisplay.money(guestAmountsCents.indices.contains(i) ? guestAmountsCents[i] : 0))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(i == guestSelectedIndex && mode == .custom ? Color(.secondarySystemBackground) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if mode == .custom {
                HStack {
                    Text("Remaining")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(ReceiptDisplay.money(remaining))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(remaining == 0 ? .secondary : .orange)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - By items panel (seeded)
    private func toggleAssignment(itemId: UUID) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard byItemItems[idx].isComplete else { return }

        let guestId = byItemSelectedGuestId
        guard activeGuests.contains(where: { $0.id == guestId }) else { return }

        if byItemItems[idx].assignedGuestIds.contains(guestId) {
            byItemItems[idx].assignedGuestIds.remove(guestId)
        } else {
            byItemItems[idx].assignedGuestIds.insert(guestId)
        }
    }

    private func byItemPanel() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a guest, then tap an item to assign/unassign them.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Receipt items")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(byItemItems.indices, id: \.self) { idx in
                        let item = byItemItems[idx]
                        let isLast = idx == byItemItems.count - 1

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if item.isComplete {
                                    Text(item.label)
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)
                                    Text(ReceiptDisplay.money(moneyToCents(item.price)))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                } else {
                                    TextField("New Item", text: $byItemItems[idx].label)
                                        .font(.system(size: 16, weight: .semibold))
                                    TextField("$", text: $byItemItems[idx].price)
                                        .font(.system(size: 13))
                                        .keyboardType(.numbersAndPunctuation)
                                }
                            }

                            Spacer()

                            HStack(spacing: 6) {
                                ForEach(item.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }, id: \.self) { gid in
                                    let fallbackIndex = guests.firstIndex(where: { $0.id == gid }) ?? 0
                                    let name = guests.first(where: { $0.id == gid }).map { displayName(for: $0, fallbackIndexInAllGuests: fallbackIndex) } ?? "Guest"
                                    ColoredCircleBadge(
                                        text: initials(name, fallback: fallbackIndex),
                                        color: colorForGuestId(gid)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if item.isComplete {
                                toggleAssignment(itemId: item.id)
                            } else if isLast {
                                // allow add row: if last placeholder becomes complete, append new placeholder
                                if !byItemItems[idx].label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   !byItemItems[idx].price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    byItemItems.append(DraftReceiptItem(id: UUID(), label: "", price: "", assignedGuestIds: []))
                                }
                            }
                        }

                        if idx != byItemItems.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Guests")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(0..<activeCount, id: \.self) { slotIndex in
                        let gid = activeGuests[slotIndex].id
                        Button {
                            byItemSelectedGuestId = gid
                        } label: {
                            HStack {
                                ColoredCircleBadge(
                                    text: initials(displayName(for: activeGuests[slotIndex], fallbackIndexInAllGuests: guests.firstIndex(where: { $0.id == gid })), fallback: slotIndex),
                                    color: colorForSlot(slotIndex)
                                )
                                Text(displayName(for: activeGuests[slotIndex], fallbackIndexInAllGuests: guests.firstIndex(where: { $0.id == gid })))
                                    .font(.system(size: 15, weight: gid == byItemSelectedGuestId ? .semibold : .regular))
                                Spacer()
                                if gid == byItemSelectedGuestId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(gid == byItemSelectedGuestId ? Color(.tertiarySystemFill) : Color.clear)
                        }
                        .buttonStyle(.plain)

                        if slotIndex != activeCount - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func openGuestEditor(_ mode: GuestEditorMode) {
      draftGuests = guests
      draftPayerGuestId = payerGuestId
      withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
        guestEditorMode = mode
        showGuestEditor = true
      }
    }

    private func applyGuestEdits() {
        // Snapshot old amounts by active guest id so custom can keep values.
        let oldActiveIds = activeGuests.map { $0.id }
        let oldAmounts: [UUID: Int] = Dictionary(uniqueKeysWithValues: zip(oldActiveIds, guestAmountsCents))

        let newGuests = draftGuests
        let newActive = newGuests.filter { $0.isIncluded }

        guests = newGuests
        payerGuestId = draftPayerGuestId

        // Keep "selected" pointer sane
        if guestSelectedIndex >= newActive.count { guestSelectedIndex = max(0, newActive.count - 1) }

        // Update per-guest amounts
        switch mode {
        case .equally:
            guestAmountsCents = equalSplitCents(total: totalCents, count: newActive.count)
        case .custom:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        case .byItems:
            // not displayed, but keep arrays sized correctly
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }

        // Ensure by-items selections/assignments stay valid
        if let first = newActive.first {
            if !newActive.contains(where: { $0.id == byItemSelectedGuestId }) {
                byItemSelectedGuestId = first.id
            }
        }
        let activeSet = Set(newActive.map { $0.id })
        byItemItems = byItemItems.map { it in
            var copy = it
            copy.assignedGuestIds = copy.assignedGuestIds.intersection(activeSet)
            return copy
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button {
                        onApply(draft())
                        onBack()
                    } label: {
                        Text("Next")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                HStack(spacing: 8) {
                    modeButton(.equally)
                    modeButton(.byItems)
                    modeButton(.custom)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // EQUALLY
                        byGuestPanel(
                            interactive: false,
                            subtitle: "Loot splits equally by default. Change the split method to edit."
                        )
                        .opacity(mode == .equally ? 1 : 0)
                        .allowsHitTesting(mode == .equally)
                        
                        // CUSTOM
                        byGuestPanel(
                            interactive: true,
                            subtitle: "Set amounts spent by each person. Fill in the circle to continue."
                        )
                        .opacity(mode == .custom ? 1 : 0)
                        .allowsHitTesting(mode == .custom)
                        
                        // BY ITEM
                        byItemPanel()
                            .opacity(mode == .byItems ? 1 : 0)
                            .allowsHitTesting(mode == .byItems)
                    }
                    .animation(.easeInOut(duration: 0.22), value: mode)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .padding(.bottom, 110)
                }
            }
        }
        .overlay(alignment: .bottom) {
            SplitGuestDrawer(
                isExpanded: $showGuestEditor,
                mode: $guestEditorMode,
                guests: $draftGuests,
                payerGuestId: $draftPayerGuestId,
                canSave: (draftGuests != guests) || (draftPayerGuestId != payerGuestId),
                onSave: { applyGuestEdits() }
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
            onRequestExpand()
        }
        .onAppear {
            // Seed guests once (or from existing draft)
            if guests.isEmpty {
                if let initialDraft, !initialDraft.guests.isEmpty {
                    guests = initialDraft.guests
                    payerGuestId = initialDraft.payerGuestId
                } else {
                    let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                    var seeded: [SplitGuest] = [SplitGuest(name: meName, isIncluded: true, isMe: true)]
                    if participantCount > 1 {
                        for _ in 1..<participantCount {
                            seeded.append(SplitGuest(name: "", isIncluded: true, isMe: false))
                        }
                    }
                    guests = seeded
                    payerGuestId = seeded.first?.id ?? UUID()
                }
            }

            if activeCount > 0 {
                if byItemSelectedGuestId == UUID() {
                    byItemSelectedGuestId = activeGuests.first?.id ?? payerGuestId
                }
            }

            ensureGuestArrays()

            if let initialDraft {
                mode = initialDraft.mode
                lastMode = initialDraft.mode

                switch initialDraft.mode {
                case .equally:
                    if initialDraft.perGuestCents.count == activeCount {
                        guestAmountsCents = initialDraft.perGuestCents
                    } else {
                        guestAmountsCents = equalSplitCents(total: totalCents, count: activeCount)
                    }

                case .custom:
                    if initialDraft.perGuestCents.count == activeCount {
                        guestAmountsCents = initialDraft.perGuestCents
                    } else {
                        guestAmountsCents = Array(repeating: 0, count: activeCount)
                    }

                case .byItems:
                    if !initialDraft.items.isEmpty {
                        didInitByItem = true
                        byItemItems = initialDraft.items.map { it in
                            DraftReceiptItem(
                                id: it.id,
                                label: it.label,
                                price: ReceiptDisplay.money(it.priceCents),
                                assignedGuestIds: Set(it.assignedGuestIds)
                            )
                        }
                    } else if !didInitByItem {
                        seedByItemsFromReceipt()
                    }
                }
            } else {
                // initial open defaults to Split Equally
                mode = .equally
                lastMode = .equally
                guestAmountsCents = equalSplitCents(total: totalCents, count: activeCount)
                if !didInitByItem { seedByItemsFromReceipt() }
            }
            
            if draftGuests.isEmpty {
                draftGuests = guests
                draftPayerGuestId = payerGuestId
            }
        }
    }
}

// MARK: - Reusable badge

private struct ColoredCircleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

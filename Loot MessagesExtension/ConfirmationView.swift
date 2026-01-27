import SwiftUI
import UIKit

struct ConfirmationView: View {
    @ObservedObject var uiModel: LootUIModel

    let receiptName: String
    let amount: String
    let participantCount: Int
    let splitMode: SplitDraft.Mode?
    let splitDraft: SplitDraft?

    let tipAmount: String
    let cameFromManual: Bool

    let onBack: () -> Void
    let onSend: () -> Void

    let onPreviewReceipt: () -> Void
    let onDeleteToLanding: () -> Void
    let onGoToSplit: () -> Void
    let onAddTip: () -> Void

    let onRequestCollapse: () -> Void

    private var isLoadingItems: Bool {
        uiModel.itemsLoadingState.isLoading
    }

    @State private var cardOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var hasSent: Bool = false
    @State private var showSuccess: Bool = false
    @State private var dragIntent: DragIntent = .none

    private enum DragIntent { case none, up, left, right }

    private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    private var upProgress: CGFloat {
        dragIntent == .up ? clamp01((-cardOffset.height) / 180) : 0
    }
    private var leftProgress: CGFloat {
        dragIntent == .left ? clamp01((-cardOffset.width) / 180) : 0
    }
    private var rightProgress: CGFloat {
        dragIntent == .right ? clamp01((cardOffset.width) / 180) : 0
    }

    private var buttonBase: Color { Color(.secondarySystemBackground) }
    private var gold: Color { Color(hex: "#DAA806") }

    private var buttonsOpacity: Double {
        if dragIntent == .up { return Double(1 - upProgress) }
        // drag left: fade everything except trash button (if it is trash)
        if dragIntent == .left { return Double(1 - leftProgress) }
        // drag right: fade everything except modify (split) button
        if dragIntent == .right { return Double(1 - rightProgress) }
        return 1
    }

    private var leftButtonIsTrash: Bool { !cameFromManual }

    // Left button “selected” styling when trash + dragging left
    private var trashSelectProgress: CGFloat {
        (dragIntent == .left && leftButtonIsTrash) ? leftProgress : 0
    }

    private var splitLabel: String {
        switch splitMode {
        case .byItems: return "Split by items"
        case .custom: return "Custom split"
        case .equally, .none: return "Split evenly"
        }
    }
    private var displayAmount: String { "$" + formatAmount(amount) }
    private var hasTip: Bool {
        !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
    }

    // Extract owed amounts and total from split draft (or compute default equal split)
    private var owedAmounts: [Int]? {
        let total = amountToCents(amount)
        
        if let draft = splitDraft {
            // Use existing split draft
            let activeGuests = draft.guests.filter { $0.isIncluded }
            guard !activeGuests.isEmpty else { return nil }
            
            // Map active guests to their owed amounts
            return activeGuests.indices.compactMap { idx in
                draft.perGuestCents.indices.contains(idx) ? draft.perGuestCents[idx] : nil
            }
        } else {
            // No draft yet - compute default equal split
            guard participantCount > 0 else { return nil }
            return equalSplit(total: total, count: participantCount)
        }
    }
    
    private var totalCents: Int? {
        if let draft = splitDraft {
            return draft.totalCents
        } else {
            return amountToCents(amount)
        }
    }
    
    // Helper to compute equal split
    private func equalSplit(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: count) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }
    
    private func amountToCents(_ str: String) -> Int {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return 0 }

        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            let cents = Int(String(cents2.prefix(2))) ?? 0
            return max(0, dollars * 100 + cents)
        } else {
            return max(0, (Int(trimmed) ?? 0) * 100)
        }
    }

    private func formatAmount(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "0.00" }

        // normalize to 2 decimals if user typed decimals
        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = parts.first ?? "0"
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            return "\(dollars).\(String(cents2.prefix(2)))"
        } else {
            return "\(trimmed).00"
        }
    }
    private var swipeCardGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                cardOffset = value.translation
                let normalized = Double(cardOffset.width / 200)
                cardRotation = 12 * min(max(normalized, -1), 1)
                
                let dx = value.translation.width
                let dy = value.translation.height

                let isMostlyHorizontal = abs(dx) > abs(dy) * 1.2
                let isMostlyVertical = abs(dy) > abs(dx) * 1.2

                if isMostlyVertical, dy < 0 {
                    dragIntent = .up
                } else if isMostlyHorizontal, dx < 0 {
                    dragIntent = .left
                } else if isMostlyHorizontal, dx > 0 {
                    dragIntent = .right
                } else {
                    dragIntent = .none
                }
            }
            .onEnded { value in
                guard !hasSent else { return }

                let dx = value.translation.width
                let dy = value.translation.height

                // Thresholds
                let horizontalTrigger: CGFloat = 120
                let verticalTrigger: CGFloat = 80

                // Decide intent by dominance (prevents diagonal confusion)
                let isMostlyHorizontal = abs(dx) > abs(dy) * 1.2
                let isMostlyVertical = abs(dy) > abs(dx) * 1.2

                // ✅ Left swipe = delete -> landing
                if isMostlyHorizontal, dx < -horizontalTrigger {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: -500, height: 0)
                        cardRotation = -6
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onDeleteToLanding()
                    }
                    dragIntent = .none
                    return
                }

                // ✅ Right swipe = go to SplitView
                if isMostlyHorizontal, dx > horizontalTrigger {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 500, height: 0)
                        cardRotation = 6
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onGoToSplit()

                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            cardOffset = .zero
                            cardRotation = 0
                        }
                    }
                    dragIntent = .none
                    return
                }


                // ✅ Up swipe = send (your existing logic)
                if isMostlyVertical, dy < -max(verticalTrigger, 50), abs(dx) < 160 {
                    hasSent = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 0, height: -400)
                        cardRotation = 0
                    }

                    withAnimation(.easeInOut(duration: 0.2)) { showSuccess = true }
                    onSend()
                    dragIntent = .none
                    return
                }

                // Otherwise snap back
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cardOffset = .zero
                    cardRotation = 0
                    dragIntent = .none
                }
            }
    }
    private func animateDeleteThenAct() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cardOffset = CGSize(width: -500, height: 0)
            cardRotation = -6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDeleteToLanding()
        }
    }

    private func animateSplitThenAct() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cardOffset = CGSize(width: 500, height: 0)
            cardRotation = 6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onGoToSplit()

            // reset so it’s visible when sheet dismisses (same fix as before)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardOffset = .zero
                cardRotation = 0
            }
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {

                Text(dragIntent == .left ? "Swipe left to delete" :
                        dragIntent == .right ? "Swipe right for split options" :
                        isLoadingItems ? "Swipe up to send without items" : "Swipe card up to send")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)

                Color.clear.frame(height: 18)

                // Card with split ring
                BillCardView(
                    receiptName: receiptName,
                    displayAmount: displayAmount,
                    displayName: myDisplayNameFromDefaults(),
                    splitLabel: splitLabel,
                    owedAmounts: owedAmounts,
                    totalCents: totalCents
                )
                .offset(cardOffset)
                .rotationEffect(.degrees(cardRotation), anchor: .bottom)
                .gesture(swipeCardGesture)
                .simultaneousGesture(TapGesture().onEnded { onPreviewReceipt() })
                .contentShape(Rectangle())
                .padding(.horizontal, 24)

                VStack(spacing: 6) {
                    if isLoadingItems {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading receipt items...")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Tap to preview receipt")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 12)
                .opacity(buttonsOpacity)

                HStack(spacing: 12) {
                    // 1) Back or Delete
                    let trashProgress = (dragIntent == .left && leftButtonIsTrash) ? leftProgress : 0

                    Button(action: {
                        if cameFromManual { onBack() } else { animateDeleteThenAct() }
                    }) {
                        Group {
                            if cameFromManual {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                            } else {
                                Image(systemName: "trash")
                            }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(
                            cameFromManual ? Color.primary : (trashProgress > 0.02 ? Color.white : Color.red)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(buttonBase)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .fill(Color.red)
                                        .opacity(Double(trashProgress))
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(dragIntent == .left && !cameFromManual ? 1 : buttonsOpacity)

                    // 2) Add Tip (same behavior/label as ManualInputView)
                    Button(action: onAddTip) {
                        Text(hasTip ? "Tip: \(tipAmount)" : "Add Tip")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(buttonBase)
                            .cornerRadius(18)
                    }
                    .buttonStyle(.plain)
                    .disabled(displayAmount == "$0" || amount.isEmpty || amount == "0")
                    .opacity((displayAmount == "$0" || amount.isEmpty || amount == "0") ? 0.4 : 1.0)
                    .opacity(buttonsOpacity)


                    // 3) Split
                    let splitProgress = (dragIntent == .right) ? rightProgress : 0

                    Button(action: { animateSplitThenAct() }) {
                        Text("Split")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(buttonBase)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18)
                                            .fill(gold)
                                            .opacity(Double(splitProgress))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .opacity(dragIntent == .right ? 1 : buttonsOpacity)


                }
                .padding(.horizontal, 40)
                .padding(.top, 16)
                .padding(.bottom, 20)

            }

            if showSuccess {
                VStack {
                    Text("Sent!")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "#06A77D"))
                .transition(.opacity)
            }
        }
        .background {
            ZStack {
                Color.black.opacity(0.10)

                Color(hex: "#06A77D").opacity(dragIntent == .up ? Double(upProgress) : 0)
                Color(hex: "#C76767").opacity(dragIntent == .left ? Double(leftProgress) : 0)
                Color(hex: "#D5C67A").opacity(dragIntent == .right ? Double(rightProgress) : 0)
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.12), value: dragIntent)
        .animation(.easeInOut(duration: 0.12), value: cardOffset)
        .task {
            onRequestCollapse()
        }
        .onAppear {
            // Reset state each time
            cardOffset = .zero
            cardRotation = 0
            hasSent = false
            showSuccess = false
        }
    }
}

private extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)

        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

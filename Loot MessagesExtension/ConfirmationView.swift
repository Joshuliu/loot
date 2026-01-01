import SwiftUI
import UIKit

struct ConfirmationView: View {
    let receiptName: String
    let amount: String
    let payerUUID: String
    let participantCount: Int
    let onBack: () -> Void
    let onSend: () -> Void
    let onPreviewReceipt: () -> Void

    @State private var cardOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var hasSent: Bool = false
    @State private var showSuccess: Bool = false

    private var displayAmount: String { "$" + formatAmount(amount) }

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

    private var swipeToSend: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !hasSent else { return }
                cardOffset = value.translation

                let maxRotation: Double = 12
                let normalized = Double(cardOffset.width / 200)
                let clamped = min(max(normalized, -1), 1)
                cardRotation = maxRotation * clamped
            }
            .onEnded { value in
                guard !hasSent else { return }

                // Only “send” if it’s a strong upward swipe
                let dx = value.translation.width
                let dy = value.translation.height
                let distance = hypot(dx, dy)

                let sendDistance: CGFloat = 80
                let mostlyUp = dy < -50 && abs(dx) < 120

                guard distance > sendDistance, mostlyUp else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = .zero
                        cardRotation = 0
                    }
                    return
                }

                hasSent = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()

                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cardOffset = CGSize(width: 0, height: -400)
                    cardRotation = 0
                }

                withAnimation(.easeInOut(duration: 0.2)) { showSuccess = true }
                onSend()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeInOut(duration: 0.2)) { showSuccess = false }
                }
            }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .padding(.leading, 16)

                    Spacer()
                }
                .padding(.top, 6)

                Text("Swipe up to send")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)

                Color.clear.frame(height: 18)

                // Card
                BillCardView(
                    receiptName: receiptName,
                    displayAmount: displayAmount,
                    payerUUID: payerUUID,
                    participantCount: participantCount
                )
                .offset(cardOffset)
                .rotationEffect(.degrees(cardRotation), anchor: .bottom)
                .gesture(swipeToSend)
                .simultaneousGesture(TapGesture().onEnded { onPreviewReceipt() })
                .contentShape(Rectangle())
                .padding(.horizontal, 24)

                Text("Tap to preview receipt")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.top, 12)

                Spacer()
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
                .transition(.opacity)
            }
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

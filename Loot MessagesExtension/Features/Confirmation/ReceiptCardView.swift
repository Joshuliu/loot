//
//  ReceiptCardView.swift
//  Loot
//
//  The bill card and the 4-way swipe gesture (up = send, left = delete,
//  right = tip, down = expand split editor). The directional cues now live
//  in ConfirmationView as tappable circle buttons flanking the card.
//  Extracted from ConfirmationView in Phase 4.
//
//  This view is "dumb": no model state, no business logic. Bindings carry
//  cardOffset/cardRotation/dragIntent/hasSent/billCardBounceYOffset/
//  introAnimationDone so the parent can drive the SwipeHintAnimator and
//  style its surrounding chrome (button row tints, drag-direction
//  background tint). Each swipe outcome is a callback the parent fills in.
//
import SwiftUI

/// Direction of the active drag on the bill card. Lifted to a top-level type
/// (was nested private inside ConfirmationView) so parent and child can share
/// the same Binding.
enum BillCardDragIntent: Equatable {
    case none, up, left, right, down
}

struct ReceiptCardView: View {
    // Card display data
    let receiptName: String
    let displayAmount: String
    let payerName: String
    let splitLabel: String
    let owedAmounts: [Int]?
    let totalCents: Int
    let tabName: String?
    let tabColorHex: String?
    let participantCount: Int
    let isLoadingReceipt: Bool

    // Sizing
    let cardScale: CGFloat
    let cardHeight: CGFloat

    // Forces BillCardView to rebuild when receipt amount/items change
    let billCardRefreshNonce: Int

    // Bindings — parent observes for styling, animator drives offset/rotation
    @Binding var cardOffset: CGSize
    @Binding var cardRotation: Double
    @Binding var dragIntent: BillCardDragIntent
    @Binding var hasSent: Bool
    @Binding var introAnimationDone: Bool
    @Binding var billCardBounceYOffset: CGFloat

    // Swipe outcomes — parent decides what each direction means
    let onSwipeUpSend: () -> Void
    let onSwipeLeftDelete: () -> Void
    let onSwipeRightTip: () -> Void
    let onSwipeDownExpand: () -> Void

    // Tap-to-edit
    let onTap: () -> Void

    var body: some View {
        cardLayer
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
    }

    // MARK: - Card layer (loading shim or live BillCardView)

    private var cardLayer: some View {
        ZStack {
            if isLoadingReceipt || !introAnimationDone {
                BillCardLoadingView(
                    participantCount: participantCount,
                    displayName: payerName,
                    tabName: tabName,
                    splitLabel: splitLabel,
                    tabColorHex: tabColorHex,
                    onAnimationComplete: {
                        introAnimationDone = true
                    }
                )
                .transition(.opacity)
            } else {
                BillCardView(
                    receiptName: receiptName,
                    displayAmount: displayAmount,
                    displayName: payerName,
                    splitLabel: splitLabel,
                    owedAmounts: owedAmounts,
                    totalCents: totalCents,
                    tabName: tabName,
                    tabColorHex: tabColorHex
                )
                .id("confirmation-bill-card-\(billCardRefreshNonce)-\(totalCents)-\(displayAmount)")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: isLoadingReceipt || !introAnimationDone)
        .cardPhysics(isDragging: cardOffset != .zero)
        .scaleEffect(cardScale)
        .frame(width: 260 * cardScale, height: cardHeight)
        .offset(x: cardOffset.width, y: cardOffset.height + billCardBounceYOffset)
        .rotationEffect(.degrees(cardRotation), anchor: .bottom)
        .gesture(swipeCardGesture)
        .simultaneousGesture(TapGesture().onEnded {
            onTap()
        })
        .contentShape(Rectangle())
        .zIndex(1)
    }

    // MARK: - 4-way swipe gesture

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
                } else if isMostlyVertical, dy > 0 {
                    dragIntent = .down
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

                // Left swipe = delete -> landing
                if isMostlyHorizontal, dx < -horizontalTrigger {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: -500, height: 0)
                        cardRotation = -6
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onSwipeLeftDelete()
                    }
                    dragIntent = .none
                    return
                }

                // Right swipe = add tip
                if isMostlyHorizontal, dx > horizontalTrigger {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 500, height: 0)
                        cardRotation = 6
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onSwipeRightTip()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            cardOffset = .zero
                            cardRotation = 0
                        }
                    }
                    dragIntent = .none
                    return
                }

                // Down swipe = expand
                if isMostlyVertical, dy > verticalTrigger {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 0, height: 500)
                        cardRotation = 6
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onSwipeDownExpand()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            cardOffset = .zero
                            cardRotation = 0
                        }
                    }
                    dragIntent = .none
                    return
                }

                // Up swipe = send
                if isMostlyVertical, dy < -max(verticalTrigger, 50), abs(dx) < 160 {
                    // Don't allow sending while phase 1 is still running (total is unknown)
                    guard !isLoadingReceipt else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            cardOffset = .zero
                            cardRotation = 0
                            dragIntent = .none
                        }
                        return
                    }
                    hasSent = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 0, height: -400)
                        cardRotation = 0
                    }
                    onSwipeUpSend()
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
}

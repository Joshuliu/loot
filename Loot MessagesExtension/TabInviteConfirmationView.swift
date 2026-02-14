//
//  TabInviteConfirmationView.swift
//  Loot MessagesExtension
//

import SwiftUI
import UIKit

struct TabInviteConfirmationView: View {
    @ObservedObject var uiModel: LootUIModel

    let tabName: String
    let tabColor: String
    let tabId: String
    let creatorName: String

    let onBack: () -> Void
    let onSend: (String, String, String) -> Void  // (tabName, tabColorHex, tabId)
    let onRequestCollapse: () -> Void

    @State private var cardOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var hasSent: Bool = false
    @State private var showSuccess: Bool = false
    @State private var dragIntent: DragIntent = .none

    private enum DragIntent { case none, up, left }

    private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    private var upProgress: CGFloat {
        dragIntent == .up ? clamp01((-cardOffset.height) / 180) : 0
    }
    private var leftProgress: CGFloat {
        dragIntent == .left ? clamp01((-cardOffset.width) / 180) : 0
    }

    private var isDragging: Bool {
        cardOffset != .zero
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                Spacer()
            }
            .padding(.vertical, 10)

            Spacer()

            if showSuccess {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("Invite Sent!")
                        .font(.system(size: 20, weight: .semibold))
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    Text("Swipe card up to invite")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(1 - upProgress)

                    // Invite card
                    TabInviteCardView(
                        tabName: tabName,
                        tabColorHex: tabColor,
                        creatorName: creatorName
                    )
                    .cardPhysics(isDragging: isDragging)
                    .offset(cardOffset)
                    .rotationEffect(.degrees(cardRotation), anchor: .bottom)
                    .gesture(swipeGesture)

                    // Hint arrows
                    VStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .opacity(1 - upProgress)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                cardOffset = value.translation
                let normalized = Double(cardOffset.width / 200)
                cardRotation = 12 * min(max(normalized, -1), 1)

                let dx = value.translation.width
                let dy = value.translation.height

                let isMostlyVertical = abs(dy) > abs(dx) * 1.2
                let isMostlyHorizontal = abs(dx) > abs(dy) * 1.2

                if isMostlyVertical, dy < 0 {
                    dragIntent = .up
                } else if isMostlyHorizontal, dx < 0 {
                    dragIntent = .left
                } else {
                    dragIntent = .none
                }
            }
            .onEnded { value in
                guard !hasSent else { return }

                let dx = value.translation.width
                let dy = value.translation.height

                let verticalTrigger: CGFloat = 80
                let horizontalTrigger: CGFloat = 120

                let isMostlyVertical = abs(dy) > abs(dx) * 1.2
                let isMostlyHorizontal = abs(dx) > abs(dy) * 1.2

                // Left swipe = cancel/back
                if isMostlyHorizontal, dx < -horizontalTrigger {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: -500, height: 0)
                        cardRotation = -6
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onBack()
                    }
                    dragIntent = .none
                    return
                }

                // Up swipe = send invite (instant — message inserted immediately)
                if isMostlyVertical, dy < -max(verticalTrigger, 50), abs(dx) < 160 {
                    hasSent = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        cardOffset = CGSize(width: 0, height: -400)
                        cardRotation = 0
                    }
                    withAnimation(.easeInOut(duration: 0.2)) { showSuccess = true }
                    onSend(tabName, tabColor, tabId)
                    onRequestCollapse()
                    dragIntent = .none
                    return
                }

                // Snap back
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cardOffset = .zero
                    cardRotation = 0
                    dragIntent = .none
                }
            }
    }
}

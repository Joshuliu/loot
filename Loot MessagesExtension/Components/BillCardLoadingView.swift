// BillCardLoadingView.swift
// Loot MessagesExtension

import SwiftUI
import UIKit

/// Animated loading card shown while phase 1 LLM analysis runs.
/// Matches BillCardView's 260×160 frame, background, and corner radius exactly.
struct BillCardLoadingView: View {
    let participantCount: Int
    let displayName: String
    var tabName: String? = nil
    var splitLabel: String = "Split evenly"
    var tabColorHex: String? = nil
    let onAnimationComplete: () -> Void

    @Environment(\.colorScheme) var colorScheme

    // Animation state
    @State private var cardScale: CGFloat = 0.85
    @State private var segProgress: [CGFloat] = []
    @State private var showSplitRow: Bool = false   // "Split method" / "Loot Tab" row — first
    @State private var showPaidByRow: Bool = false  // "Paid by" row — second
    @State private var pulseOpacity: Double = 0.4
    @State private var topDotOpacity: Double = 0

    private var isDarkMode: Bool { colorScheme == .dark }
    private var hasTabColor: Bool { tabColorHex != nil }
    private var primaryFg: Color { hasTabColor ? .white : .primary }
    private var secondaryFg: Color { hasTabColor ? .white.opacity(0.7) : .secondary }

    private var safeParticipantCount: Int { max(1, participantCount) }

    var body: some View {
        HStack(alignment: .bottom) {
            // Left column — mirrors BillCardView's left column exactly
            VStack(alignment: .leading, spacing: 8) {
                // Receipt name shimmer placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerColor)
                    .frame(width: 72, height: 13)

                VStack(alignment: .leading, spacing: 6) {
                    // Row 1: "Split method" / "Loot Tab" (matches BillCardView row 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tabName == nil ? "Split method" : "Loot Tab")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)
                            .opacity(showSplitRow ? 1 : 0)
                            .offset(y: showSplitRow ? 0 : 8)

                        Text(tabName ?? splitLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                            .opacity(showSplitRow ? 1 : 0)
                            .offset(y: showSplitRow ? 0 : 8)
                    }

                    // Row 2: "Paid by" (matches BillCardView row 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid by")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)
                            .opacity(showPaidByRow ? 1 : 0)
                            .offset(y: showPaidByRow ? 0 : 8)

                        Text(displayName.isEmpty ? "Me" : displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(showPaidByRow ? 1 : 0)
                            .offset(y: showPaidByRow ? 0 : 8)
                    }
                }
            }
            .frame(width: 90, alignment: .leading)

            // Right side — animated donut ring
            loadingRingView
                .frame(width: 120, height: 110)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(width: 260, height: 160, alignment: .center)
        .background(cardBackground)
        .cornerRadius(13)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
        .scaleEffect(cardScale)
        .onAppear {
            startAnimation()
        }
    }

    // MARK: - Ring View

    private var loadingRingView: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineW: CGFloat = 16
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - lineW / 2
            let handleRadius = radius + lineW / 2

            ZStack {
                // Background track
                Circle()
                    .stroke(
                        hasTabColor ? Color.white.opacity(0.2) : Color(UIColor.secondarySystemBackground),
                        style: .init(lineWidth: lineW, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .position(center)

                // Animated segments — reversed so last arc sits on top at 12 o'clock
                ForEach((0..<safeParticipantCount).reversed(), id: \.self) { i in
                    if i < segProgress.count {
                        let segFrac = 1.0 / CGFloat(safeParticipantCount)
                        let segStart = segFrac * CGFloat(i)
                        let rawEnd = segStart + segFrac * segProgress[i]
                        let segEnd = min(rawEnd, segStart + segFrac)

                        if segEnd > segStart {
                            Circle()
                                .trim(from: segStart, to: segEnd)
                                .stroke(
                                    BadgeColors.color(for: i),
                                    style: .init(lineWidth: lineW, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: size, height: size)
                                .position(center)
                        }
                    }
                }

                // Top dot at 12 o'clock — rendered last so it sits above all arcs
                let dotIdx = safeParticipantCount - 1
                let ang: CGFloat = -.pi / 2
                let hx = center.x + handleRadius * cos(ang)
                let hy = center.y + handleRadius * sin(ang)
                Circle()
                    .fill(BadgeColors.color(for: dotIdx))
                    .frame(width: 16, height: 16)
                    .position(x: hx, y: hy)
                    .opacity(topDotOpacity)

                // Center pulsing dots
                Text("•••")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(primaryFg)
                    .opacity(pulseOpacity)
                    .position(center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var shimmerColor: Color {
        hasTabColor
            ? Color.white.opacity(0.25)
            : Color(.tertiarySystemFill)
    }

    private var cardBackground: some View {
        Group {
            if let hex = tabColorHex {
                Color(hex: hex)
            } else {
                Color(isDarkMode ? UIColor.systemBackground : UIColor.secondarySystemBackground)
                    .overlay(Color.white.opacity(isDarkMode ? 0.018 : 0))
            }
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        segProgress = Array(repeating: 0, count: safeParticipantCount)

        // Card spring pop
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            cardScale = 1.0
        }

        // Sequential segment sweeps
        let segDuration = 0.35
        for i in 0..<safeParticipantCount {
            let delay = 0.1 + segDuration * Double(i)
            withAnimation(.easeInOut(duration: segDuration).delay(delay)) {
                segProgress[i] = 1.0
            }
        }

        // Top dot fades in as the last arc completes
        let lastSegDelay = 0.1 + segDuration * Double(safeParticipantCount - 1)
        withAnimation(.easeIn(duration: segDuration).delay(lastSegDelay)) {
            topDotOpacity = 1.0
        }

        // Labels appear after all arcs finish — split method row first, paid by row second
        let allSegsEnd = 0.1 + segDuration * Double(safeParticipantCount)
        withAnimation(.easeOut(duration: 0.35).delay(allSegsEnd)) {
            showSplitRow = true
        }
        withAnimation(.easeOut(duration: 0.35).delay(allSegsEnd + 0.3)) {
            showPaidByRow = true
        }

        // Pulsing center dots
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(0.3)) {
            pulseOpacity = 1.0
        }

        // Notify completion after all animations
        let totalAnimTime = allSegsEnd + 0.3 + 0.35 + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + totalAnimTime) {
            onAnimationComplete()
        }
    }
}

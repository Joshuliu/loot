// BillCardLoadingView.swift
// Loot MessagesExtension

import SwiftUI

/// Animated loading card shown while phase 1 LLM analysis runs.
/// Matches BillCardView's 260×160 frame, background, and corner radius exactly.
struct BillCardLoadingView: View {
    let participantCount: Int
    let displayName: String
    var tabColorHex: String? = nil
    let onAnimationComplete: () -> Void

    @Environment(\.colorScheme) var colorScheme

    // Animation state
    @State private var cardScale: CGFloat = 0.85
    @State private var segProgress: [CGFloat] = []
    @State private var showPaidBy: Bool = false
    @State private var showSplitWith: Bool = false
    @State private var pulseOpacity: Double = 0.4

    private var isDarkMode: Bool { colorScheme == .dark }
    private var hasTabColor: Bool { tabColorHex != nil }
    private var primaryFg: Color { hasTabColor ? .white : .primary }
    private var secondaryFg: Color { hasTabColor ? .white.opacity(0.7) : .secondary }

    private var safeParticipantCount: Int { max(1, participantCount) }

    var body: some View {
        HStack(alignment: .bottom) {
            // Left column — mirrors BillCardView's left column
            VStack(alignment: .leading, spacing: 8) {
                // Receipt name shimmer placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerColor)
                    .frame(width: 72, height: 13)

                VStack(alignment: .leading, spacing: 6) {
                    // "Paid by" section
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid by")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)
                            .opacity(showPaidBy ? 1 : 0)
                            .offset(y: showPaidBy ? 0 : 8)

                        Text(displayName.isEmpty ? "Me" : displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(showPaidBy ? 1 : 0)
                            .offset(y: showPaidBy ? 0 : 8)
                    }

                    // "Split with N people" section
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Split with")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)
                            .opacity(showSplitWith ? 1 : 0)
                            .offset(y: showSplitWith ? 0 : 8)

                        Text("\(safeParticipantCount) \(safeParticipantCount == 1 ? "person" : "people")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                            .opacity(showSplitWith ? 1 : 0)
                            .offset(y: showSplitWith ? 0 : 8)
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

            ZStack {
                // Background track
                Circle()
                    .stroke(
                        hasTabColor ? Color.white.opacity(0.2) : Color(.secondarySystemBackground),
                        style: .init(lineWidth: lineW, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .position(center)

                // Animated segments
                ForEach(0..<safeParticipantCount, id: \.self) { i in
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
                Color(isDarkMode ? .systemBackground : .secondarySystemBackground)
                    .overlay(Color.white.opacity(isDarkMode ? 0.018 : 0))
            }
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        // Initialize segment progress array
        segProgress = Array(repeating: 0, count: safeParticipantCount)

        // Card spring pop
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            cardScale = 1.0
        }

        // Staggered segment sweeps: t=0.1 + 0.25*i per segment
        let segDuration = 0.4
        let segStagger = 0.25
        for i in 0..<safeParticipantCount {
            let delay = 0.1 + segStagger * Double(i)
            withAnimation(.easeOut(duration: segDuration).delay(delay)) {
                segProgress[i] = 1.0
            }
        }

        // "Paid by" label appears at t=0.5
        withAnimation(.easeOut(duration: 0.35).delay(0.5)) {
            showPaidBy = true
        }

        // "Split with N people" label appears at t=0.85
        withAnimation(.easeOut(duration: 0.35).delay(0.85)) {
            showSplitWith = true
        }

        // Pulsing center dots
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(0.3)) {
            pulseOpacity = 1.0
        }

        // Notify completion: after all segments + labels have animated
        let totalAnimTime = 0.85 + 0.35 + 0.1
        let delay = max(totalAnimTime, 0.1 + segStagger * Double(safeParticipantCount - 1) + segDuration + 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            onAnimationComplete()
        }
    }
}

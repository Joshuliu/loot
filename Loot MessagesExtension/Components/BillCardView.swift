//
//  BillCardView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//
import SwiftUI
import UIKit

struct BillCardView: View {
    @Environment(\.colorScheme) var colorScheme
    var isDarkMode: Bool {
        colorScheme == .dark
    }
    let receiptName: String
    let displayAmount: String
    let displayName: String
    let splitLabel: String
    
    let owedAmounts: [Int]?  // Owed amounts in cents for each person
    let totalCents: Int?      // Total in cents
    var tabName: String? = nil
    var tabColorHex: String? = nil

    private var hasTabColor: Bool { tabColorHex != nil }
    private var primaryFg: Color { hasTabColor ? .white : .primary }
    private var secondaryFg: Color { hasTabColor ? .white.opacity(0.7) : .secondary }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(receiptName.isEmpty ? "New Receipt" : receiptName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(primaryFg)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: 95, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tabName == nil ? "Split method" : "Loot Tab")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)

                        Text(tabName ?? splitLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid by")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryFg)

                        Text(displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(width: 90, alignment: .leading)

            // Right side - Ring
            if let owedAmounts = owedAmounts, let totalCents = totalCents, !owedAmounts.isEmpty {
                SplitRingView(
                    participantCount: owedAmounts.filter { $0 != 0}.count,
                    owedAmounts: owedAmounts,
                    totalCents: totalCents,
                    displayAmount: displayAmount,
                    tabColorHex: tabColorHex
                )
                .frame(width: 120, height: 110, alignment: .center)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(width: 260, height: 160, alignment: .center)
        .background(
            Group {
                if let hex = tabColorHex {
                    Color(hex: hex)
                } else {
                    Color(isDarkMode ? .systemBackground : .secondarySystemBackground)
                        .overlay(
                            Color.white.opacity(isDarkMode ? 0.018 : 0)
                        )
                }
            }
        )
        .cornerRadius(13)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)

    }
}

// MARK: - Settlement Card (compact, ~1/3 height of BillCardView)

struct SettlementCardView: View {
    let fromName: String
    let toName: String
    let amountCents: Int
    let methodName: String
    var tabColorHex: String? = nil
    var isRequest: Bool = false

    private var bgColor: Color {
        if let hex = tabColorHex { return Color(hex: hex) }
        return Color(.secondarySystemBackground)
    }
    private var fg: Color  { tabColorHex != nil ? .white : .primary }
    private var sub: Color { tabColorHex != nil ? .white.opacity(0.7) : .secondary }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Left col: SENT/REQUESTED + amount
            VStack(alignment: .leading, spacing: 2) {
                Text(isRequest ? "REQUESTED" : "SENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(sub)
                Text(ReceiptDisplay.money(amountCents))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(fg)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Divider
            Rectangle()
                .fill(fg.opacity(0.2))
                .frame(width: 1, height: 36)
                .padding(.horizontal, 12)

            // Right col: via/from _ / to ___
            VStack(alignment: .leading, spacing: 2) {
                Text(isRequest ? "from" : "via \(methodName)")
                    .font(.system(size: 11))
                    .foregroundColor(sub)
                    .lineLimit(1)
                if !isRequest {
                    Text(toName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(fg)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 52)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .frame(width: 260, height: 60)
        .background(bgColor)
        .cornerRadius(13)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Split Ring Component

private struct SplitRingView: View {
    let participantCount: Int
    let owedAmounts: [Int]
    let totalCents: Int
    let displayAmount: String
    var tabColorHex: String? = nil
    
    private var safeTotal: Int {
        max(1, totalCents)  // Avoid division by zero
    }
    
    private func sumBefore(_ idx: Int) -> Int {
        guard idx > 0 else { return 0 }
        return owedAmounts.prefix(idx).reduce(0, +)
    }
    
    private func sumThrough(_ idx: Int) -> Int {
        return owedAmounts.prefix(idx + 1).reduce(0, +)
    }

    private func lastActiveIndex(idx: Int) -> Int {
        for j in stride(from: idx - 1, through: 0, by: -1) {
            if owedAmounts[j] > 0 {
                return j
            }
        }
        return 0
    }
    
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)  // Use available space
            let lineW: CGFloat = 16  // Slightly thicker for bigger ring
            let radius = size / 2 - lineW / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let handleRadius = radius + lineW / 2
            
            ZStack {
                // Background ring
                Circle()
                    .stroke(tabColorHex != nil ? Color.white.opacity(0.2) : Color(.secondarySystemBackground),
                            style: .init(lineWidth: lineW, lineCap: .round))
                    .frame(width: size, height: size)

                // Colored segments
                ForEach(0..<owedAmounts.count, id: \.self) { i in
                    let start = Double(sumBefore(i)) / Double(safeTotal)
                    let end = Double(sumThrough(i)) / Double(safeTotal)

                    if end > start {
                        Circle()
                            .trim(from: start, to: end)
                            .stroke(BadgeColors.color(for: i),
                                    style: .init(lineWidth: lineW, lineCap: .round))
                            .opacity(1)
                            .rotationEffect(.degrees(-90))
                            .frame(width: size, height: size)
                    }

                    // Segment dividers (small circles)
                    if i > 0 {
                        let ang = -(.pi / 1.99) + (start * 2 * .pi)
                        let hx = center.x + handleRadius * cos(ang)
                        let hy = center.y + handleRadius * sin(ang)
                        let colorIdx = lastActiveIndex(idx: i)
                        if sumBefore(i) < sumThrough(i) && owedAmounts[colorIdx] > 0 {
                            Circle()
                                .fill(BadgeColors.color(for: colorIdx))
                                .overlay(
                                    Circle().stroke(BadgeColors.color(for: colorIdx), lineWidth: 0.05)
                                )
                                .frame(width: 16, height: 16)
                                .position(x: hx, y: hy)
                        }
                    }
                }

                // Center text - Total amount
                VStack(spacing: 2) {
                    Text(displayAmount)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(tabColorHex != nil ? .white : .primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                        Text("Split \(participantCount) \(participantCount == 1 ? "way" : "ways")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(tabColorHex != nil ? .white.opacity(0.7) : .secondary)
                }
                .frame(width: size - lineW * 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


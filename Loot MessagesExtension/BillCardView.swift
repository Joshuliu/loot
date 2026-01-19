//
//  BillCardView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//
import SwiftUI
import UIKit

struct BillCardView: View {
    let receiptName: String
    let displayAmount: String
    let displayName: String
    let participantCount: Int
    let splitLabel: String
    
    let owedAmounts: [Int]?  // Owed amounts in cents for each person
    let totalCents: Int?      // Total in cents

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(receiptName.isEmpty ? "New Receipt" : receiptName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: 95, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Split method")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Text(splitLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid by")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        Text(displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(width: 90, alignment: .leading)

            // Right side - Ring
            if let owedAmounts = owedAmounts, let totalCents = totalCents, !owedAmounts.isEmpty {
                SplitRingView(
                    participantCount: participantCount,
                    owedAmounts: owedAmounts,
                    totalCents: totalCents,
                    displayAmount: displayAmount
                )
                .frame(width: 120, height: 110, alignment: .center)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(width: 250, height: 150, alignment: .center)
        .background(
            Color(.systemBackground).overlay(Color.white.opacity(0.08))
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)

    }
}

// MARK: - Split Ring Component

private struct SplitRingView: View {
    let participantCount: Int
    let owedAmounts: [Int]
    let totalCents: Int
    let displayAmount: String
    
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
                    .stroke(Color(.secondarySystemBackground),
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
                            .rotationEffect(.degrees(-90))
                            .frame(width: size, height: size)
                    }
                    
                    // Segment dividers (small circles)
                    if i > 0 {
                        let ang = -(.pi / 1.99) + (start * 2 * .pi)
                        let hx = center.x + handleRadius * cos(ang)
                        let hy = center.y + handleRadius * sin(ang)
                        
                        Circle()
                            .fill(BadgeColors.color(for: i - 1))
                            .overlay(
                                Circle().stroke(BadgeColors.color(for: i - 1), lineWidth: 0.05)
                            )
                            .frame(width: 16, height: 16)
                            .position(x: hx, y: hy)
                    }
                }
                
                // Center text - Total amount
                VStack(spacing: 2) {
                    Text(displayAmount)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    
                        Text("Split \(participantCount) \(participantCount == 1 ? "way" : "ways")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                }
                .frame(width: size - lineW * 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

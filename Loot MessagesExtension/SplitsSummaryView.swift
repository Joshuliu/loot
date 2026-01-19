//
//  SplitsSummaryView.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI

struct SplitsSummaryView: View {
    let split: SplitPayload

    @State private var selectedIndex: Int = 0

    private var includedIndices: [Int] {
        split.g.indices.filter { split.g[$0].inc }
    }

    private var safeTotal: Int {
        max(0, split.tot)
    }

    private func displayName(for idx: Int) -> String {
        let g = split.g[idx]
        let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if g.me { return "Me" }
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

    private func sumBeforeIncludedSlot(_ includedSlot: Int) -> Int {
        guard includedSlot > 0 else { return 0 }
        let prev = includedIndices.prefix(includedSlot)
        return prev.reduce(0) { $0 + owed(for: $1) }
    }

    private func sumThroughIncludedSlot(_ includedSlot: Int) -> Int {
        let upTo = includedIndices.prefix(includedSlot + 1)
        return upTo.reduce(0) { $0 + owed(for: $1) }
    }

    var body: some View {
        let included = includedIndices
        let count = included.count
        let selectedIncludedSlot = max(0, min(selectedIndex, max(0, count - 1)))
        let selectedGuestIndex = count > 0 ? included[selectedIncludedSlot] : 0
        let selectedCents = owed(for: selectedGuestIndex)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GeometryReader { geo in
                    let size = min(geo.size.width, 230)
                    let lineW: CGFloat = 30
                    let radius = size / 2 - lineW / 2
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let handleRadius = radius + lineW / 2

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
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: size, height: size)
                                }
                                if count > 0, i > 0 {
                                    let ang = -(.pi / 1.95) + (start * 2 * .pi)
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
                        Button {
                            selectedIndex = i
                        } label: {
                            HStack {
                                ColoredCircleBadge(
                                    text: BadgeColors.initials(from: displayName(for: gi), fallback: gi),
                                    color: colorForSlot(i)
                                )

                                Text(displayName(for: gi))
                                    .font(.system(size: 15, weight: i == selectedIndex ? .semibold : .regular))
                                Spacer()
                                Text(ReceiptDisplay.money(owed(for: gi)))
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(i == selectedIndex ? Color(.secondarySystemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Tiny "by items" hint (optional but useful)
                if split.m == .byItems {
                    Text("Items are saved per person inside this message.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }
}

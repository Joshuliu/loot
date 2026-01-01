//
//  ReceiptView.swift
//  Bill
//
//  Created by Joshua Liu on 12/11/25.
//

import SwiftUI

struct ReceiptView: View {
    let receipt: ReceiptDisplay
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Inline back row so it’s always visible without NavigationStack
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

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.title)
                            .font(.system(size: 28, weight: .bold))

                        Text(receipt.dateText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    // Items box
                    VStack(spacing: 0) {
                        ForEach(receipt.items) { item in
                            HStack(alignment: .center, spacing: 12) {

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)

                                    Text(ReceiptDisplay.money(item.priceCents))
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 6) {
                                    ForEach(item.responsible, id: \.slotIndex) { who in
                                        CircleBadge(text: who.badgeText)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)

                            if item.id != receipt.items.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    // Totals box
                    TotalsBox(receipt: receipt)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)

                }
            }
        }
    }
}

// MARK: - Small UI bits

private struct CircleBadge: View {
    let text: String
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
        }
    }
}

private struct TotalsBox: View {
    let receipt: ReceiptDisplay

    var body: some View {
        VStack(spacing: 10) {
            if receipt.shouldShowOnlyTotal {
                Row(label: "Total", value: receipt.totalCents)
            } else {
                Row(label: "Subtotal", value: receipt.subtotalCents)

                if receipt.feesCents != 0 { Row(label: "Fees", value: receipt.feesCents) }
                if receipt.taxCents != 0 { Row(label: "Tax", value: receipt.taxCents) }
                if receipt.tipCents != 0 { Row(label: "Tip", value: receipt.tipCents) }
                if receipt.discountCents != 0 { Row(label: "Discount", value: receipt.discountCents) }

                Divider()

                Row(label: "Total", value: receipt.totalCents, bold: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private struct Row: View {
        let label: String
        let value: Int
        var bold: Bool = false

        var body: some View {
            HStack {
                Text(label)
                    .font(.system(size: 15, weight: bold ? .semibold : .regular))
                Spacer()
                Text(ReceiptDisplay.money(value))
                    .font(.system(size: 15, weight: bold ? .semibold : .regular))
            }
        }
    }
}

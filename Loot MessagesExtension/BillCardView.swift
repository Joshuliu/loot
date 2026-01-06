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
    let payerUUID: String
    let participantCount: Int
    let splitLabel: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(receiptName.isEmpty ? "New Receipt" : receiptName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(displayAmount)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Who pays")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Text(payerUUID)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Split with")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Text("\(participantCount) \(participantCount == 1 ? "person" : "people")")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }

                    Text(splitLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Spacer()
        }
        .background(
            Color(.systemBackground)
                .overlay(Color.white.opacity(0.08))
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
        .frame(width: 250, height: 150, alignment: .topLeading)
    }
}

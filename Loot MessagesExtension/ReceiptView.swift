//
//  ReceiptView.swift
//  Bill
//
//  Created by Joshua Liu on 12/11/25.
//

import SwiftUI
import UIKit

struct ReceiptView: View {
    @ObservedObject var uiModel: LootUIModel
    let receipt: ReceiptDisplay
    let onBack: () -> Void

    var showBackRow: Bool = true
    @State private var showCapture: Bool = false
    @State private var showEditReceipt: Bool = false

    private var captureImage: UIImage? {
        uiModel.scanImageCropped ?? uiModel.scanImageOriginal
    }

    private var isLoadingItems: Bool {
        uiModel.itemsLoadingState.isLoading
    }
    
    struct TopRoundedRectangle: Shape {
        var radius: CGFloat = 20

        func path(in rect: CGRect) -> Path {
            let path = UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: radius, height: radius)
            )
            return Path(path.cgPath)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if showBackRow {
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
                    
                    Button(action: { showEditReceipt = true }) {
                        Text("Edit")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
                .padding(.vertical, 10)
            }
            
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
                        if isLoadingItems {
                            // Loading state
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.9)
                                Text("Loading items...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else if receipt.items.isEmpty {
                            // Empty state
                            VStack(spacing: 8) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text("No items")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            // Items list
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
                                            ColoredCircleBadge(
                                                text: who.badgeText,
                                                color: BadgeColors.color(for: who.slotIndex)
                                            )
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
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    
                    // Totals box
                    TotalsBox(receipt: receipt)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 90)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Button {
                showCapture = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder")
                    Text("View capture")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
                .padding(.horizontal, 18)
            }
            .buttonStyle(.plain)
            .opacity(1)
            .padding(.top, 25)
            .background(Color(.systemBackground).opacity(0.95))
            .clipShape(TopRoundedRectangle(radius: 20))
//            .opacity(captureImage == nil ? 0 : 1)
//            .padding(.horizontal, 14)
//            .background(Color(.systemBackground).opacity(captureImage == nil ? 0: 1))
//            .background(Color(.systemBackground).opacity(1))
            .allowsHitTesting(captureImage != nil)
        }
        .sheet(isPresented: $showCapture) {
            CapturePreviewView(image: captureImage) {
                showCapture = false
            }
        }
        .sheet(isPresented: $showEditReceipt) {
            EditReceiptView(
                uiModel: uiModel,
                onSave: { updatedReceipt in
                    uiModel.currentReceipt = updatedReceipt
                    showEditReceipt = false
                },
                onCancel: {
                    showEditReceipt = false
                }
            )
        }
    }
}

// MARK: - Capture preview sheet

private struct CapturePreviewView: View {
    let image: UIImage?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(14)
            }

            if let image {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(Color.black.opacity(0.9))
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                Spacer()
                Text("No capture available")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color.black.opacity(0.9))
        .ignoresSafeArea()
    }
}

// MARK: - Totals box

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

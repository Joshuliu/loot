//
//  MessageReceiptViewer.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI

struct MessageReceiptViewer: View {
    @ObservedObject var uiModel: LootUIModel
    let payload: LootMessagePayload
    let onClose: () -> Void

    enum Tab { case splits, receipt }
    @State private var tab: Tab = .splits

    private var captureImage: UIImage? {
        uiModel.scanImageCropped ?? uiModel.scanImageOriginal
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {

                Spacer()

                Text(tab == .splits ? "Splits" : "Receipt")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Content
            ZStack {
                if tab == .splits {
                    SplitsSummaryView(split: payload.s)
                        .transition(.opacity)
                } else {
                    if let receipt = uiModel.currentReceipt {
                        ReceiptView(uiModel: uiModel, receipt: receipt, onBack: {}, showBackRow: false)
                            .transition(.opacity)
                    } else {
                        ProgressView("Loading…")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: tab)

            // Bottom menu bar
            HStack(spacing: 10) {
                bottomTabButton("Splits", system: "chart.pie.fill", selected: tab == .splits) { tab = .splits }
                bottomTabButton("Receipt", system: "doc.text.fill", selected: tab == .receipt) { tab = .receipt }
            }
            .padding(.horizontal, 14)
            .padding(.top, captureImage != nil ? 40: 10)
            .padding(.bottom, 14)
            .background(Color(.secondarySystemBackground))
            .shadow(color: Color.black.opacity(captureImage == nil ? 1 : 0), radius: 18, x: 0, y: -2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bottomTabButton(_ title: String, system: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? Color.blue : Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

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
        TabView(selection: $tab) {
            SplitsSummaryView(uiModel: uiModel, split: payload.s, items: payload.r.i)
                .id(uiModel.openedMessageDocId ?? payload.r.id)
                .tabItem { Label("Splits", systemImage: "chart.pie.fill") }
                .tag(Tab.splits)

            Group {
                if let receipt = uiModel.currentReceipt {
                    ReceiptView(uiModel: uiModel, receipt: receipt, onBack: {}, showBackRow: false, showCaptureButton: true, compactCaptureButton: true)
                } else {
                    ProgressView("Loading…")
                }
            }
            .tabItem { Label("Receipt", systemImage: "doc.text.fill") }
            .tag(Tab.receipt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            guard #unavailable(iOS 26) else { return }
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

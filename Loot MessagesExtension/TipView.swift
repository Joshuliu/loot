//
//  TipView.swift
//  Loot
//
//  Created by Assistant
//

import SwiftUI

struct TipView: View {
    let subtotalString: String
    let onBack: () -> Void
    let onNext: (String, String) -> Void  // (tipAmount, newTotal)
    
    @State private var tipPercent: Double = 15.0
    
    private let minPercent: Double = 0
    private let maxPercent: Double = 100
    
    // Convert string to cents for calculations
    private var subtotalCents: Int {
        let cleaned = subtotalString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        
        guard !cleaned.isEmpty else { return 0 }
        
        if cleaned.contains(".") {
            let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            let cents = Int(String(cents2.prefix(2))) ?? 0
            return dollars * 100 + cents
        }
        
        return (Int(cleaned) ?? 0) * 100
    }
    
    private var tipCents: Int {
        Int(round(Double(subtotalCents) * (tipPercent / 100.0)))
    }
    
    private var totalCents: Int {
        subtotalCents + tipCents
    }
    
    private func formatMoney(_ cents: Int) -> String {
        let dollars = cents / 100
        let centsRemainder = cents % 100
        return "$\(dollars).\(String(format: "%02d", centsRemainder))"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .padding(.leading, 16)
                Spacer()
            }
            .padding(.vertical, 12)
            
            ScrollView {
                VStack(spacing: 24) {
                    // Title
                    Text("Add Tip")
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.top, 8)
                    
                    // Equation display (horizontal)
                    HStack(spacing: 12) {
                        // Subtotal
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subtotal")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(formatMoney(subtotalCents))
                                .font(.system(size: 22, weight: .bold))
                        }
                        
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                        
                        // Tip
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tip (\(String(format: "%.0f", tipPercent))%)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(formatMoney(tipCents))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.blue)
                        }
                        
                        Image(systemName: "equal")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                        
                        // Total
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(formatMoney(totalCents))
                                .font(.system(size: 22, weight: .bold))
                        }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)
                    
                    // Percentage slider
                    VStack(spacing: 16) {
                        Text("Scroll to adjust tip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        PercentageSlider(
                            percent: $tipPercent,
                            minPercent: minPercent,
                            maxPercent: maxPercent
                        )
                        .frame(height: 60)
                        .padding(.horizontal, 24)
                    }
                    
                    Spacer().frame(height: 20)
                }
            }
            
            // Bottom buttons
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("Back")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(18)
                }
                
                Button(action: {
                    onNext(formatMoney(tipCents), formatMoney(totalCents))
                }) {
                    Text("Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemBlue))
                        .cornerRadius(18)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Percentage Slider Component
struct PercentageSlider: View {
    @Binding var percent: Double
    let minPercent: Double
    let maxPercent: Double
    
    var body: some View {
        GeometryReader { geometry in
            let itemWidth: CGFloat = 60
            let centerX = geometry.size.width / 2
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: centerX - itemWidth / 2)
                        
                        itemsView(itemWidth: itemWidth)
                        
                        Color.clear.frame(width: centerX - itemWidth / 2)
                    }
                    .background(
                        GeometryReader { scrollGeo in
                            Color.clear
                                .onChange(of: scrollGeo.frame(in: .named("scroll")).minX) { _, offset in
                                    let index = -offset / 65.66
                                    let newPercent = minPercent + index
                                    if newPercent >= minPercent && newPercent <= maxPercent {
                                        percent = newPercent
                                    }
                                }
                        }
                    )
                }
                .coordinateSpace(name: "scroll")
                .overlay(centerLine(height: geometry.size.height, centerX: centerX))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(Int(percent), anchor: .center)
                    }
                }
            }
        }
    }
    
    private func itemsView(itemWidth: CGFloat) -> some View {
        ForEach(Int(minPercent)...Int(maxPercent), id: \.self) { value in
            itemRow(value: value, itemWidth: itemWidth)
        }
    }
    
    private func itemRow(value: Int, itemWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("\(value)%")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(abs(Double(value) - percent) < 0.5 ? .blue : .secondary)
                .frame(width: itemWidth)
                .id(value)
            
            if value < Int(maxPercent) {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
            }
        }
    }
    
    private func offsetReader() -> some View {
        GeometryReader { scrollGeo in
            Color.clear.preference(
                key: ScrollOffsetKey.self,
                value: scrollGeo.frame(in: .named("scroll")).minX
            )
        }
    }
    
    private func centerLine(height: CGFloat, centerX: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue)
            .frame(width: 2, height: height)
            .position(x: centerX, y: height / 2)
            .allowsHitTesting(false)
    }
    
    private func updatePercent(offset: CGFloat, centerX: CGFloat, itemWidth: CGFloat) {
        let adjustedOffset = -offset + centerX - itemWidth / 2
        let index = adjustedOffset / itemWidth
        let newPercent = minPercent + index
        if newPercent >= minPercent && newPercent <= maxPercent {
            percent = newPercent
        }
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

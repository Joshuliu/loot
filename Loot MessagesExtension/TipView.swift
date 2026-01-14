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
            ScrollView {
                VStack(spacing: 12) {
                    // Receipt-style breakdown
                    VStack(spacing: 0) {
                        // Subtotal row
                        HStack {
                            Text("Subtotal")
                                .font(.system(size: 15, weight: .regular))
                            Spacer()
                            Text(formatMoney(subtotalCents))
                                .font(.system(size: 15, weight: .regular))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        
                        // Tip row
                        HStack {
                            Text("Tip (\(String(format: "%.0f", tipPercent))%)")
                                .font(.system(size: 15, weight: .regular))
                            Spacer()
                            Text(formatMoney(tipCents))
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        
                        Divider()
                            .padding(.horizontal, 16)
                        
                        // Total row
                        HStack {
                            Text("Total")
                                .font(.system(size: 17, weight: .semibold))
                            Spacer()
                            Text(formatMoney(totalCents))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)
                    
                    // Percentage slider
                    VStack(spacing: 16) {
                        PercentageSlider(
                            percent: $tipPercent,
                            minPercent: minPercent,
                            maxPercent: maxPercent
                        )
                        .frame(height: 60)
                        .padding(.horizontal, 24)
                        
                        Text("Scroll to adjust tip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
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
                    onNext(formatMoney(tipCents).replacingOccurrences(of: "$", with: ""), formatMoney(totalCents).replacingOccurrences(of: "$", with: ""))
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

struct PercentageSlider: View {
    @Binding var percent: Double
    let minPercent: Double
    let maxPercent: Double

    private let itemWidth: CGFloat = 60
    private let dotWidth: CGFloat = 5.866667
    private var stride: CGFloat { itemWidth + dotWidth }

    @State private var isReadyToTrackScroll = false

    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let sidePad = centerX - itemWidth / 2

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: sidePad)

                        HStack(spacing: 0) {
                            ForEach(Int(minPercent)...Int(maxPercent), id: \.self) { value in
                                HStack(spacing: 0) {
                                    Text("\(value)%")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(abs(Double(value) - percent) < 0.5 ? .blue : .secondary)
                                        .frame(width: itemWidth)
                                        .id(value)

                                    if value < Int(maxPercent) {
                                        Text("•")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.blue)
                                            .frame(width: dotWidth) // critical: makes stride deterministic
                                    }
                                }
                            }
                        }

                        Color.clear.frame(width: sidePad)
                    }
                    .background(
                        GeometryReader { scrollGeo in
                            Color.clear
                                .onChange(of: scrollGeo.frame(in: .named("scroll")).minX) { _, offset in
                                    guard isReadyToTrackScroll else { return }

                                    let index = (-offset) / stride
                                    let newPercent = minPercent + Double(index)
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
                    // Preserve initial value (e.g. 15%) without layout overwriting it.
                    DispatchQueue.main.async {
                        proxy.scrollTo(Int(percent.rounded()), anchor: .center)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            isReadyToTrackScroll = true
                        }
                    }
                }
            }
        }
    }

    private func centerLine(height: CGFloat, centerX: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue)
            .frame(width: 2, height: height)
            .position(x: centerX, y: height / 2)
            .allowsHitTesting(false)
    }
}


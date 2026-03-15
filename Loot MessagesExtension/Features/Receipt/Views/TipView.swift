import SwiftUI

// MARK: - TipPanelView
// Shared tip UI used both as an inline panel in ConfirmationView and as the
// standalone .tipview screen reached from ManualInputView.

struct TipPanelView: View {
    let preTipTotalCents: Int
    let existingTipCents: Int
    let isExpanded: Bool
    let onBack: () -> Void
    let onApply: (String, String) -> Void  // (tipStr, totalStr) — no "$" prefix

    private enum TipEditField: Hashable { case tip, total }
    @State private var tipPercent: Double = 15.0
    @State private var hasInitialized: Bool = false
    @State private var tipEditingField: TipEditField? = nil
    @State private var tipManualInput: String = ""
    @State private var manualTipOverrideCents: Int? = nil
    @State private var isUpdatingPercentFromManualInput: Bool = false
    @FocusState private var tipInputFocused: TipEditField?

    private var sliderTipCents: Int {
        Int(round(Double(preTipTotalCents) * (tipPercent / 100.0)))
    }

    private var totalWithTipCents: Int {
        preTipTotalCents + sliderTipCents
    }

    private func manualTipCents(from input: String, field: TipEditField?) -> Int? {
        guard let field else { return nil }
        switch field {
        case .tip:
            return max(0, stringToCents(input))
        case .total:
            return max(0, stringToCents(input) - preTipTotalCents)
        }
    }

    private var manualTipCentsWhileEditing: Int? {
        manualTipCents(from: tipManualInput, field: tipEditingField)
    }

    private var effectiveTipCents: Int {
        manualTipCentsWhileEditing ?? manualTipOverrideCents ?? sliderTipCents
    }

    private var effectiveTotalCents: Int {
        preTipTotalCents + effectiveTipCents
    }

    private var appliedTipCents: Int {
        effectiveTipCents
    }

    private var appliedTotalCents: Int {
        effectiveTotalCents
    }

    private func cappedSliderPercent(forManualTip tipCents: Int) -> Double {
        guard preTipTotalCents > 0 else { return tipCents > 0 ? 100 : 0 }
        let rawPercent = (Double(tipCents) / Double(preTipTotalCents)) * 100.0
        return min(100, max(0, rawPercent))
    }

    private func sanitizedUSDAmountInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var integerPart = ""
        var fractionalPart = ""
        var hasDecimalSeparator = false

        for char in trimmed {
            if char.isWholeNumber {
                if hasDecimalSeparator {
                    if fractionalPart.count < 2 {
                        fractionalPart.append(char)
                    }
                } else {
                    integerPart.append(char)
                }
            } else if char == "." && !hasDecimalSeparator {
                hasDecimalSeparator = true
            }
        }

        if integerPart.isEmpty {
            integerPart = "0"
        } else {
            integerPart = String(integerPart.drop { $0 == "0" })
            if integerPart.isEmpty {
                integerPart = "0"
            }
        }

        if hasDecimalSeparator {
            return "\(integerPart).\(fractionalPart)"
        }

        return integerPart
    }

    private func normalizedUSDAmount(_ raw: String) -> String {
        let sanitized = sanitizedUSDAmountInput(raw)
        guard !sanitized.isEmpty else { return "" }
        return centsToDecimalString(stringToCents(sanitized))
    }

    private func updateManualTipInput(_ newValue: String, field: TipEditField) {
        let sanitized = sanitizedUSDAmountInput(newValue)
        if sanitized != newValue {
            tipManualInput = sanitized
            return
        }

        let manualTipCents = manualTipCents(from: sanitized, field: field) ?? 0
        manualTipOverrideCents = manualTipCents
        isUpdatingPercentFromManualInput = true
        tipPercent = cappedSliderPercent(forManualTip: manualTipCents)
        isUpdatingPercentFromManualInput = false
    }

    private func cancelKeyboardEditing() {
        tipInputFocused = nil
        tipEditingField = nil
        tipManualInput = ""
    }

    private func finishKeyboardEditing() {
        let field = tipEditingField
        let normalizedInput = normalizedUSDAmount(tipManualInput)
        tipManualInput = normalizedInput
        if let manualTipCents = manualTipCents(from: normalizedInput, field: field) {
            manualTipOverrideCents = manualTipCents
            isUpdatingPercentFromManualInput = true
            tipPercent = cappedSliderPercent(forManualTip: manualTipCents)
            isUpdatingPercentFromManualInput = false
        }
        tipInputFocused = nil
        tipEditingField = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    Spacer()

                    VStack(spacing: 0) {
                        // Pre-tip total (static)
                        HStack {
                            Text("Pre-tip total")
                                .font(.system(size: 14, weight: .regular))
                            Spacer()
                            Text(ReceiptDisplay.money(preTipTotalCents))
                                .font(.system(size: 14, weight: .regular))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        // Tip row — tap to enter manually
                        HStack {
                            Text("Tip (\(String(format: "%.0f", tipPercent))%)")
                                .font(.system(size: 14, weight: .regular))
                            Spacer()
                            if tipEditingField == .tip {
                                TextField("0.00", text: $tipManualInput)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.blue)
                                    .keyboardType(.decimalPad)
                                    .focused($tipInputFocused, equals: .tip)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize()
                                    .onChange(of: tipManualInput) { _, newValue in
                                        updateManualTipInput(newValue, field: .tip)
                                    }
                            } else {
                                Button {
                                    tipManualInput = centsToDecimalString(effectiveTipCents)
                                    tipEditingField = .tip
                                    tipInputFocused = .tip
                                } label: {
                                    Text(ReceiptDisplay.money(effectiveTipCents))
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider()
                            .padding(.horizontal, 16)

                        // Total row — tap to enter manually; offset from pre-tip becomes the tip
                        HStack {
                            Text("Total")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if tipEditingField == .total {
                                TextField("0.00", text: $tipManualInput)
                                    .font(.system(size: 15, weight: .semibold))
                                    .keyboardType(.decimalPad)
                                    .focused($tipInputFocused, equals: .total)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize()
                                    .onChange(of: tipManualInput) { _, newValue in
                                        updateManualTipInput(newValue, field: .total)
                                    }
                            } else {
                                Button {
                                    tipManualInput = centsToDecimalString(effectiveTotalCents)
                                    tipEditingField = .total
                                    tipInputFocused = .total
                                } label: {
                                    Text(ReceiptDisplay.money(effectiveTotalCents))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 24)

                    VStack(spacing: 16) {
                        PercentageSlider(
                            percent: $tipPercent,
                            minPercent: 0,
                            maxPercent: 100
                        )
                            .frame(height: 60)
                            .padding(.horizontal, 24)
                            .onTapGesture { tipEditingField = nil }
                            .onChange(of: tipPercent) { _, _ in
                                guard tipEditingField == nil, !isUpdatingPercentFromManualInput else { return }
                                guard let manualTipOverrideCents else { return }
                                let cappedManualPercent = cappedSliderPercent(forManualTip: manualTipOverrideCents)
                                if abs(tipPercent - cappedManualPercent) > 0.001 {
                                    self.manualTipOverrideCents = nil
                                }
                            }

                        if isExpanded {
                            Text(tipEditingField == nil ? "Scroll to adjust • Tap a % to jump" : "Tap amount again to edit")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
            }
            .padding(.top, isExpanded ? 10 : 0)

            HStack(spacing: 12) {
                Button(action: {
                    tipEditingField = nil
                    onBack()
                }) {
                    Text("Back")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(18)
                }
                .buttonStyle(.plain)

                Button(action: {
                    let tipStr = ReceiptDisplay.money(appliedTipCents).replacingOccurrences(of: "$", with: "")
                    let totalStr = ReceiptDisplay.money(appliedTotalCents).replacingOccurrences(of: "$", with: "")
                    tipEditingField = nil
                    onApply(tipStr, totalStr)
                }) {
                    Text("Apply")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemBlue))
                        .cornerRadius(18)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 40)
            .padding(.top, 5)
            .padding(.bottom, 18)
        }
        .padding(.top, 9)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Cancel") {
                    cancelKeyboardEditing()
                }
                Spacer()
                Button("Done") {
                    finishKeyboardEditing()
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            if existingTipCents > 0 {
                isUpdatingPercentFromManualInput = true
                tipPercent = cappedSliderPercent(forManualTip: existingTipCents)
                isUpdatingPercentFromManualInput = false
                if existingTipCents != sliderTipCents {
                    manualTipOverrideCents = existingTipCents
                }
            }
        }
    }
}

// MARK: - PercentageSlider

struct PercentageSlider: View {
    @Binding var percent: Double
    let minPercent: Double
    let maxPercent: Double

    private let itemWidth: CGFloat = 60
    private let dotWidth: CGFloat = 5.866667
    private var stride: CGFloat { itemWidth + dotWidth }

    @State private var isReadyToTrackScroll = false
    @State private var isProgrammaticScroll = false

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
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            scrollTo(value, proxy: proxy)
                                        }

                                    if value < Int(maxPercent) {
                                        Text("•")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.blue)
                                            .frame(width: dotWidth)
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
                                    guard !isProgrammaticScroll else { return }

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

    private func scrollTo(_ value: Int, proxy: ScrollViewProxy) {
        let clamped = min(max(value, Int(minPercent)), Int(maxPercent))
        isProgrammaticScroll = true
        percent = Double(clamped)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            proxy.scrollTo(clamped, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            isProgrammaticScroll = false
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

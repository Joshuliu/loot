//
//  ManualInputView.swift (UPDATED with Tip functionality)
//  Bill
//
//  Created by Joshua Liu on 12/9/25.
//

import SwiftUI
import Combine
import UIKit

struct ManualInputView: View {
    @ObservedObject var viewModel: LootUIModel
    @Binding var receiptName: String
    @Binding var amountString: String
    @Binding var tipAmount: String
    
    let onBack: () -> Void
    let onNext: () -> Void
    let onAddTip: () -> Void
    let onRequestExpand: () -> Void
    let onRequestCollapse: () -> Void
    let titleNamespace: Namespace.ID

    @State private var bump: Bool = false
    
    // Hold-to-repeat state
    @State private var holdTimer: Timer?
    @State private var holdCount: Int = 0
    
    // Animation state
    @State private var animationTrigger: Int = 0
    
    @State private var didAppear = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    private var displayAmount: String {
        "$" + (amountString.isEmpty ? "0" : amountString)
    }
    
    private var hasTip: Bool {
        !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
    }

    var body: some View {
        VStack {
            // Top bar
            Spacer().frame(height: 36)
            
            // Title / receipt name
            TextField("New Receipt", text: $receiptName)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(receiptName.isEmpty ? .gray : .primary)
                .matchedGeometryEffect(id: "receiptTitle", in: titleNamespace)
                .padding(.horizontal, 24)

            // Expense amount with - and +
            HStack(spacing: 24) {
                // Decrement button
                Button(action: {
                    decrementAmount()
                }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 28, weight: .regular))
                }
                .onLongPressGesture(
                    minimumDuration: 0.4,
                    maximumDistance: 20,
                    pressing: { isPressing in
                        if isPressing {
                            startHolding(increment: false)
                        } else {
                            stopHolding()
                        }
                    },
                    perform: { }
                )

                // Amount text
                Text(displayAmount)
                    .font(.system(size: 32, weight: .bold))
                    .animation(.easeInOut(duration: 0.15), value: bump)
                    .onTapGesture {
                        toggleNumpad(expand: true)
                    }

                // Increment button
                Button(action: {
                    incrementAmount()
                }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 28, weight: .regular))
                }
                .onLongPressGesture(
                    minimumDuration: 0.4,
                    maximumDistance: 20,
                    pressing: { isPressing in
                        if isPressing {
                            startHolding(increment: true)
                        } else {
                            stopHolding()
                        }
                    },
                    perform: { }
                )
            }
            .padding(.top, 16)
            
            // Numpad vs "Enter exact amount"
            if viewModel.isExpanded {
                NumpadView(
                    onTapDigit: { digit in
                        appendDigit(digit)
                    },
                    onTapDot: {
                        appendDot()
                    },
                    onDelete: {
                        deleteLast()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 8)
            } else {
                Button(action: {
                    toggleNumpad(expand: true)
                }) {
                    Text("Enter exact amount")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 16)
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Group {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(Color.primary)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(18)
                }
                .buttonStyle(.plain)
                
                // Add a tip button
                Button(action: onAddTip) {
                    Text(hasTip ? "Tip: \(tipAmount)" : "Add Tip")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(Color.primary)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(18)
                }
                .disabled(displayAmount == "$0" || amountString.isEmpty || amountString == "0")
                .opacity((displayAmount == "$0" || amountString.isEmpty || amountString == "0") ? 0.4 : 1.0)
                
                // Next button
                Button(action: onNext) {
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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            didAppear = true
            haptic.prepare()
        }
        .onChange(of: amountString) {
            guard didAppear else { return }
            haptic.impactOccurred()
            haptic.prepare()
        }
        .onDisappear {
            stopHolding()
        }

    }
}

// MARK: - Hold-to-repeat logic

private extension ManualInputView {
    func startHolding(increment: Bool) {
        if holdTimer != nil { return }

        holdCount = 0

        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            holdCount += 1

            // Accelerate: more repeats as you hold longer
            let speedMultiplier = min(1 + (holdCount / 10), 10)

            for _ in 0..<speedMultiplier {
                if increment {
                    incrementAmount()
                } else {
                    decrementAmount()
                }
            }
        }
    }

    func stopHolding() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdCount = 0
    }
}

// MARK: - Amount helpers

private extension ManualInputView {
    func incrementAmount() {
        if amountString.contains(".") {
            // Preserve cents, bump only the dollar part
            let parts = amountString.split(
                separator: ".",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let dollarPart = Int(parts.first ?? "0") ?? 0
            let centsPart = parts.count > 1 ? String(parts[1]) : nil

            let newDollars = dollarPart + 1
            if let centsPart, !centsPart.isEmpty {
                amountString = "\(newDollars).\(centsPart)"
            } else {
                amountString = "\(newDollars)"
            }
        } else {
            let current = Int(amountString) ?? 0
            amountString = String(current + 1)
        }
        animationTrigger += 1
        bump.toggle()
    }

    func decrementAmount() {
        if amountString.contains(".") {
            // Preserve cents, bump only the dollar part
            let parts = amountString.split(
                separator: ".",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let dollarPart = Int(parts.first ?? "0") ?? 0
            let centsPart = parts.count > 1 ? String(parts[1]) : nil

            let newDollars = max(0, dollarPart - 1)
            if newDollars == 0 && (centsPart == nil || centsPart?.isEmpty == true) {
                amountString = "0"
            } else if let centsPart, !centsPart.isEmpty {
                amountString = "\(newDollars).\(centsPart)"
            } else {
                amountString = "\(newDollars)"
            }
        } else {
            let current = Int(amountString) ?? 0
            let next = max(0, current - 1)
            amountString = String(next)
        }
        animationTrigger += 1
        bump.toggle()
    }

    func appendDigit(_ d: String) {
        if let dotIndex = amountString.firstIndex(of: ".") {
            let afterDot = amountString.index(after: dotIndex)
            let fractional = amountString[afterDot...]
            
            // Limit to two decimal places
            if fractional.count >= 2 {
                return
            }
            amountString.append(d)
        } else {
            if amountString == "0" {
                amountString = d
            } else {
                amountString.append(d)
            }
        }
    }

    func appendDot() {
        if !amountString.contains(".") {
            amountString.append(".")
        }
    }

    func deleteLast() {
        guard !amountString.isEmpty else { return }
        
        amountString.removeLast()
        
        if amountString.isEmpty {
            amountString = "0"
        }
    }

    func toggleNumpad(expand: Bool) {
        if expand {
            onRequestExpand()
        } else {
            onRequestCollapse()
        }
    }
}

// MARK: - Numpad

struct NumpadView: View {
    let onTapDigit: (String) -> Void
    let onTapDot: () -> Void
    let onDelete: () -> Void

    private let columns: [[NumpadKey]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.dot, .digit("0"), .delete]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<columns.count, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(columns[row]) { key in
                        Button(action: { handleTap(key) }) {
                            Text(key.title)
                                .font(.system(size: 22, weight: .medium))
                                .frame(width: 60, height: 60)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }
                }
            }
        }
    }

    private func handleTap(_ key: NumpadKey) {
        switch key {
        case .digit(let d):
            onTapDigit(d)
        case .dot:
            onTapDot()
        case .delete:
            onDelete()
        }
    }
}

enum NumpadKey: Identifiable {
    case digit(String)
    case dot
    case delete

    var id: String { title }

    var title: String {
        switch self {
        case .digit(let d): return d
        case .dot: return "."
        case .delete: return "⌫"
        }
    }
}

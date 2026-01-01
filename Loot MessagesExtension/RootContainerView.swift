//
//  RootContainerView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//


import SwiftUI

struct RootContainerView: View {
    @ObservedObject var uiModel: LootUIModel

    @State private var screen: Screen = .fill
    @State private var receiptName: String = ""
    @State private var amountString: String = "0"
    @State private var returnScreen: Screen = .fill
    @Namespace private var titleNamespace

    let payerUUID: String
    let participantCount: Int

    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void

    // Camera sheet state
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
    @State private var isAnalyzing: Bool = false
    @State private var analyzeError: String?

    init(uiModel: LootUIModel) {
        self.uiModel = uiModel
        self.payerUUID = ""
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
    }
    
    init(
        uiModel: LootUIModel,
        payerUUID: String,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void
    ) {
        self.uiModel = uiModel
        self.payerUUID = payerUUID
        self.participantCount = participantCount
        self.onScan = onScan
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onSendBill = onSendBill
    }

    // MARK: - Helpers

    private func amountToCents(_ str: String) -> Int {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return 0 }

        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsPart = parts.count > 1 ? String(parts[1]) : ""
            let cents2: Int
            if centsPart.isEmpty {
                cents2 = 0
            } else if centsPart.count == 1 {
                cents2 = Int(centsPart + "0") ?? 0
            } else {
                cents2 = Int(String(centsPart.prefix(2))) ?? 0
            }
            return dollars * 100 + cents2
        } else {
            let dollars = Int(trimmed) ?? 0
            return dollars * 100
        }
    }

    private func makePreviewReceipt() -> ReceiptDisplay {
        let cents = amountToCents(amountString)
        return ReceiptDisplay(
            id: "preview",
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: cents,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 0,
            totalCents: cents,
            items: []
        )
    }

    private func startScanFlow() {
        onScan()
        showCamera = true
        analyzeError = nil
    }

    private func analyzeCaptured(image: UIImage) {
        isAnalyzing = true
        analyzeError = nil

        let developerMessage = """
You are a receipt-to-JSON extractor and verifier. Use ONLY the receipt image as evidence; never invent merchants, dates, items, or amounts—if unclear, set null and add an issue. Output ONLY valid JSON that matches the provided JSON Schema (no markdown, no extra keys). All money values must be integer cents; do the math checks to verify that items add up to totals; prefer conservative extraction over guessing.
"""

        let userMessage = """
Parse the attached receipt image into the JSON Schema below, then verify the math.
Rules:
- Money → integer cents (e.g., $12.34 => 1234). Quantity is integer >= 1.
- If you can’t confidently read a value, use null (or 0 only when the field truly doesn’t exist) and add an entry to issues[].
- Do NOT “fix” the receipt by making numbers up to match—compute and report the mismatch.
- Treat “Total” on the receipt as total_cents when present.

JSON Schema:
{
  "type": "object",
  "additionalProperties": false,
  "required": ["merchant", "created_at_iso", "currency", "items", "subtotal_cents", "tax_cents", "fees_cents", "tip_cents", "discount_cents", "total_cents", "verification", "issues"],
  "properties": {
    "merchant": { "type": ["string","null"] },
    "created_at_iso": { "type": ["string","null"], "description": "ISO 8601 if visible, else null" },
    "currency": { "type": ["string","null"], "description": "e.g., USD" },

    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["label", "quantity", "unit_price_cents", "line_total_cents", "confidence"],
        "properties": {
          "label": { "type": "string" },
          "quantity": { "type": "integer", "minimum": 1 },
          "unit_price_cents": { "type": ["integer","null"], "minimum": 0, "description": "null if not shown" },
          "line_total_cents": { "type": ["integer","null"], "minimum": 0, "description": "null if not shown" },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
        }
      }
    },

    "subtotal_cents": { "type": ["integer","null"], "minimum": 0 },
    "tax_cents": { "type": ["integer","null"], "minimum": 0 },
    "fees_cents": { "type": ["integer","null"], "minimum": 0 },
    "tip_cents": { "type": ["integer","null"], "minimum": 0 },
    "discount_cents": { "type": ["integer","null"], "minimum": 0 },
    "total_cents": { "type": ["integer","null"], "minimum": 0 },

    "verification": {
      "type": "object",
      "additionalProperties": false,
      "required": ["items_sum_cents", "computed_total_cents", "delta_total_cents", "passed"],
      "properties": {
        "items_sum_cents": { "type": ["integer","null"], "minimum": 0, "description": "sum of line_total_cents when available; else null" },
        "computed_total_cents": { "type": ["integer","null"], "minimum": 0, "description": "subtotal + tax + fees + tip - discount when those fields exist; else null" },
        "delta_total_cents": { "type": ["integer","null"], "description": "total_cents - computed_total_cents when both exist; else null" },
        "passed": { "type": "boolean", "description": "true if abs(delta_total_cents) <= 5 (rounding tolerance) OR delta is null due to missing values" }
      }
    },

    "issues": {
      "type": "array",
      "items": { "type": "string" },
      "description": "human-readable problems/ambiguities, e.g. 'Could not read total', 'Subtotal missing', 'Total mismatch by 23 cents'"
    }
  }
}
"""

        Task {
            defer { isAnalyzing = false }
            do {
                let parsed = try await LLMClient.shared.analyzeReceipt(
                    image: image,
                    developerMessage: developerMessage,
                    userMessage: userMessage
                )

                await MainActor.run {
                    uiModel.parsedReceipt = parsed

                    // Prefill form fields
                    if let total = parsed.total_cents {
                        amountString = String(format: "%.2f", Double(total) / 100.0)
                    }
                    if let merchant = parsed.merchant, !merchant.isEmpty {
                        receiptName = merchant
                    }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        screen = .confirmation
                    }
                }
            } catch {
                print("[Scan] analyzeReceipt failed: \(error)")
                await MainActor.run {
                    analyzeError = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            switch screen {
            case .fill:
                FillReceiptView(
                    viewModel: uiModel,
                    receiptName: $receiptName,
                    amountString: $amountString,
                    onBack: {
                        onCollapse()
                    },
                    onNext: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            screen = .confirmation
                        }
                    },
                    onRequestExpand: onExpand,
                    onRequestCollapse: onCollapse,
                    titleNamespace: titleNamespace
                )
                .transition(.opacity)
                .overlay(alignment: .bottom) {
                    // MVP Scan CTA (if FillReceiptView doesn’t already have it)
                    Button {
                        startScanFlow()
                    } label: {
                        Text("Scan receipt")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(14)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                    }
                }

            case .confirmation:
                ConfirmationView(
                    receiptName: receiptName,
                    amount: amountString,
                    payerUUID: payerUUID,
                    participantCount: participantCount,
                    onBack: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            screen = .fill
                        }
                    },
                    onSend: {
                        onSendBill(receiptName, amountString)

                        // MVP reset back to fill for rapid repeats
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                screen = .fill
                            }
                        }
                    },
                    onPreviewReceipt: {
                        uiModel.currentReceipt = makePreviewReceipt()
                        returnScreen = .confirmation
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            screen = .receipt
                        }
                    }
                )
                .transition(.opacity)

            case .receipt:
                if let receipt = uiModel.currentReceipt {
                    ReceiptView(receipt: receipt) {
                        uiModel.currentReceipt = nil
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            screen = returnScreen
                        }
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .sheet(isPresented: $showCamera, onDismiss: {
            if let img = capturedImage {
                analyzeCaptured(image: img)
            }
        }) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .overlay {
            if isAnalyzing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Analyzing receipt…")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                }
            }
        }
        .alert("Scan failed", isPresented: Binding(
            get: { analyzeError != nil },
            set: { _ in analyzeError = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(analyzeError ?? "")
        }
    }
}

enum Screen {
    case fill
    case confirmation
    case receipt
}

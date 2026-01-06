//
//  IntroView.swift
//  Loot
//
//  Created by Joshua Liu on 1/5/26.
//


import SwiftUI

struct IntroView: View {
    let onRequestExpand: () -> Void
    let onContinue: (String) -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 8)

            Text("Welcome to LOOT")
                .font(.system(size: 28, weight: .bold))

            Text("Easily split bills with a receipt. Enter your name to start splitting your loot!")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Enter display name", text: $name)
                .textContentType(.name)                 // encourages iOS name autofill / suggestions
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.continue)
                .focused($nameFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator), lineWidth: 1)
                )
                .onSubmit {
                    guard canContinue else { return }
                    onContinue(trimmed)
                }

            Button {
                onContinue(trimmed)
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
            .opacity(canContinue ? 1.0 : 0.4)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            onRequestExpand()

            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { nameFocused = true }

            // focus again after the expand transition is more likely finished
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run { nameFocused = true }
        }
    }
}

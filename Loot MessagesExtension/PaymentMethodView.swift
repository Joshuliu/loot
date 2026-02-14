//
//  PaymentMethodView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct PaymentMethodView: View {
    let onBack: () -> Void
    let onRequestExpand: () -> Void
    let onSaved: () -> Void
    var isPostSendPrompt: Bool = false

    @State private var methods: [PaymentMethod] = []
    @State private var isSaving: Bool = false

    private var availableTypes: [PaymentMethodType] {
        let added = Set(methods.map(\.type))
        return PaymentMethodType.allCases.filter { !added.contains($0) }
    }

    private var canSave: Bool {
        guard !methods.isEmpty else { return false }
        return methods.allSatisfy { method in
            !method.type.requiresIdentifier || !method.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Back button
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 10)

            // Title
            Text(isPostSendPrompt ? "Set Up Payment Methods" : "Payment Methods")
                .font(.system(size: 24, weight: .bold))

            if isPostSendPrompt {
                Text("Let people know how to pay you")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Added methods
                    if !methods.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                                methodRow(index: index, method: method)
                                if index < methods.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    // Available methods to add
                    if !availableTypes.isEmpty {
                        Text("Add a method")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ], spacing: 10) {
                            ForEach(availableTypes, id: \.rawValue) { type in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        methods.append(PaymentMethod(type: type, identifier: ""))
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: type.iconName)
                                            .font(.system(size: 16))
                                        Text(type.displayName)
                                            .font(.system(size: 15, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.tertiarySystemBackground))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(.separator), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Save button
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        } else {
                            Text("Save")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
                    .opacity(canSave && !isSaving ? 1.0 : 0.4)

                    // Skip button (post-send only)
                    if isPostSendPrompt {
                        Button(action: onSaved) {
                            Text("Skip for Now")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            methods = savedPaymentMethods()
        }
        .task {
            onRequestExpand()
        }
    }

    // MARK: - Method Row

    @ViewBuilder
    private func methodRow(index: Int, method: PaymentMethod) -> some View {
        HStack(spacing: 12) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 14))

            // Icon
            Image(systemName: method.type.iconName)
                .font(.system(size: 18))
                .frame(width: 24)

            // Name + identifier
            VStack(alignment: .leading, spacing: 4) {
                Text(method.type.displayName)
                    .font(.system(size: 15, weight: .medium))

                if method.type.requiresIdentifier {
                    TextField(method.type.identifierPlaceholder, text: Binding(
                        get: { methods.indices.contains(index) ? methods[index].identifier : "" },
                        set: { newValue in
                            if methods.indices.contains(index) {
                                methods[index].identifier = newValue
                            }
                        }
                    ))
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                }
            }

            Spacer()

            // Move up/down buttons
            VStack(spacing: 2) {
                if index > 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            methods.swapAt(index, index - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if index < methods.count - 1 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            methods.swapAt(index, index + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Remove button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    _ = methods.remove(at: index)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        isSaving = true
        savePaymentMethodsToDefaults(methods)

        Task {
            let userId = KeychainHelper.getOrCreateUserId()
            try? await TabService.shared.updatePaymentMethods(userId: userId, methods: methods)
            await MainActor.run {
                isSaving = false
                onSaved()
            }
        }
    }
}

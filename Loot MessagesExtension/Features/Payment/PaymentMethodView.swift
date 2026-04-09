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
    @State private var zelleSheetItem: ZelleSheetItem? = nil

    // Drag-to-reorder state
    @State private var draggingId: String? = nil
    @State private var dragStartIndex: Int = 0
    @State private var dragTranslation: CGFloat = 0
    @FocusState private var focusedIdentifierMethodId: String?
    private let rowHeight: CGFloat = 52

    private struct ZelleSheetItem: Identifiable { let id: Int }

    private var availableTypes: [PaymentMethodType] {
        let added = Set(methods.map(\.type))
        return PaymentMethodType.allCases.filter { !added.contains($0) }
    }

    private var canSave: Bool {
        guard !methods.isEmpty else { return false }
        return methods.allSatisfy { method in
            if method.type == .zelle {
                return !(method.zelleData ?? "").isEmpty && !(method.bankURL ?? "").isEmpty
            }
            guard method.type.requiresIdentifier else { return true }
            if method.type == .venmo {
                // Venmo keeps a visible "@" prefix; validate the username content after it.
                return !method.identifier
                    .replacingOccurrences(of: "@", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            return !method.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func venmoUsername(from raw: String) -> String {
        raw
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes identifier input while preserving Venmo UX rules:
    /// - show "@" only while focused (or when a username already exists),
    /// - prevent additional "@" characters,
    /// - allow placeholder to reappear on blur when username is empty.
    private func normalizedIdentifierInput(_ raw: String, for type: PaymentMethodType, isFocused: Bool) -> String {
        guard type == .venmo else { return raw }
        let username = venmoUsername(from: raw)
        if username.isEmpty {
            return isFocused ? "@" : ""
        }
        return "@\(username)"
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

            Text("Let others know how to pay you! Guests using the same payment methods can pay you in your preferred methods.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.78)

            // Draggable methods list — intentionally outside ScrollView
            // so the ScrollView's pan gesture can't interfere with the drag gesture.
            if !methods.isEmpty {
                ZStack(alignment: .top) {
                    // Clipped card — dragged row is opacity(0) but still holds the gesture
                    VStack(spacing: 0) {
                        ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                            methodRow(index: index, method: method)
                                .frame(height: rowHeight)
                                .overlay(alignment: .bottom) {
                                    if index < methods.count - 1 {
                                        Divider().padding(.leading, 44)
                                    }
                                }
                                .background(Color(.secondarySystemBackground))
                                .opacity(draggingId == method.id ? 0 : 1)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .coordinateSpace(name: "reorderList")

                    // Floating copy — positioned from startIndex + raw translation,
                    // so it never jumps when the array reorders underneath.
                    if let dId = draggingId,
                       let idx = methods.firstIndex(where: { $0.id == dId }) {
                        methodRow(index: idx, method: methods[idx])
                            .frame(height: rowHeight)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                            .offset(y: CGFloat(dragStartIndex) * rowHeight + dragTranslation)
                            .allowsHitTesting(false)
                    }
                }
            }

            // The rest (add buttons + save) can scroll if needed
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
            // Canonicalize persisted Venmo identifiers so existing values render consistently.
            methods = methods.map { method in
                guard method.type == .venmo else { return method }
                var copy = method
                copy.identifier = normalizedIdentifierInput(copy.identifier, for: .venmo, isFocused: false)
                return copy
            }
            guard UserDefaults.standard.bool(forKey: DefaultsKeys.pendingZelleReopen) else { return }
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingZelleReopen)
            let bName = UserDefaults.standard.string(forKey: DefaultsKeys.pendingZelleBankName) ?? ""
            let bURL  = UserDefaults.standard.string(forKey: DefaultsKeys.pendingZelleBankURL) ?? ""
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingZelleBankName)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingZelleBankURL)

            if let idx = methods.firstIndex(where: { $0.type == .zelle }) {
                if (methods[idx].bankURL ?? "").isEmpty, !bURL.isEmpty {
                    methods[idx].bankName = bName
                    methods[idx].bankURL  = bURL
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    zelleSheetItem = ZelleSheetItem(id: idx)
                }
            } else if !bURL.isEmpty {
                var m = PaymentMethod(type: .zelle, identifier: "")
                m.bankName = bName
                m.bankURL  = bURL
                methods.append(m)
                let idx = methods.count - 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    zelleSheetItem = ZelleSheetItem(id: idx)
                }
            }
        }
        .onChange(of: focusedIdentifierMethodId) { oldValue, newValue in
            // When leaving a Venmo field, remove a bare "@" so placeholder returns.
            guard let oldValue, oldValue != newValue else { return }
            guard let idx = methods.firstIndex(where: { $0.id == oldValue }) else { return }
            guard methods[idx].type == .venmo else { return }
            methods[idx].identifier = normalizedIdentifierInput(methods[idx].identifier, for: .venmo, isFocused: false)
        }
        .task {
            onRequestExpand()
        }
        .sheet(item: $zelleSheetItem) { item in
            let idx = item.id
            if methods.indices.contains(idx) {
                ZelleSetupSheet(existing: methods[idx]) { bName, bURL, identifier, data in
                    methods[idx].bankName = bName
                    methods[idx].bankURL = bURL
                    methods[idx].identifier = identifier
                    methods[idx].zelleData = data
                }
            }
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
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("reorderList"))
                        .onChanged { val in
                            if draggingId == nil {
                                draggingId = method.id
                                dragStartIndex = index
                            }
                            guard draggingId == method.id else { return }
                            dragTranslation = val.translation.height

                            // Where the dragged item visually is, in fractional row units
                            let fractional = CGFloat(dragStartIndex) + dragTranslation / rowHeight

                            guard let currentIdx = methods.firstIndex(where: { $0.id == method.id }) else { return }

                            // Compute target with 0.6 hysteresis to prevent oscillation
                            var target = currentIdx
                            while fractional > CGFloat(target) + 0.6 && target < methods.count - 1 {
                                target += 1
                            }
                            while fractional < CGFloat(target) - 0.6 && target > 0 {
                                target -= 1
                            }

                            guard target != currentIdx else { return }
                            let toOffset = target > currentIdx ? target + 1 : target
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                methods.move(fromOffsets: IndexSet(integer: currentIdx),
                                             toOffset: toOffset)
                            }
                        }
                        .onEnded { _ in
                            guard let finalIdx = methods.firstIndex(where: { $0.id == draggingId }) else {
                                draggingId = nil
                                dragTranslation = 0
                                return
                            }
                            // Snap floating copy to the final row position
                            let snap = CGFloat(finalIdx - dragStartIndex) * rowHeight
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                                dragTranslation = snap
                            }
                            // Then reveal the real row
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                draggingId = nil
                                dragTranslation = 0
                            }
                        }
                )

            // Icon
            Image(systemName: method.type.iconName)
                .font(.system(size: 18))
                .frame(width: 24)

            // Name
            Text(method.type.displayName)
                .font(.system(size: 15, weight: .medium))

            Spacer()

            // Identifier
            VStack(alignment: .trailing, spacing: 4) {
                if method.type.requiresIdentifier {
                    TextField(method.type.identifierPlaceholder, text: Binding(
                        get: {
                            guard methods.indices.contains(index) else { return "" }
                            let current = methods[index]
                            let isFocused = (focusedIdentifierMethodId == current.id)
                            return normalizedIdentifierInput(current.identifier, for: current.type, isFocused: isFocused)
                        },
                        set: { newValue in
                            if methods.indices.contains(index) {
                                let current = methods[index]
                                let isFocused = (focusedIdentifierMethodId == current.id)
                                methods[index].identifier = normalizedIdentifierInput(newValue, for: current.type, isFocused: isFocused)
                            }
                        }
                    ))
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .focused($focusedIdentifierMethodId, equals: method.id)
                }

                if method.type == .zelle {
                    Button {
                        zelleSheetItem = ZelleSheetItem(id: index)
                    } label: {
                        if let data = method.zelleData, !data.isEmpty {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(method.identifier)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let bName = method.bankName {
                                    Text(bName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 13))
                                Text("Set Up")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

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

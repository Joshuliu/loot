import SwiftUI

struct TabPayNowSheet: View {
    let toName: String
    let amountCents: Int
    let methods: [PaymentMethod]
    var tabColorHex: String? = nil
    let onSelectMethod: (PaymentMethod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var myMethods: [PaymentMethod] = []
    @State private var showingPaymentMethodSetup = false

    private var mutualMethods: [PaymentMethod] {
        let myTypes = Set(myMethods.map(\.type))
        return methods.filter { myTypes.contains($0.type) }
    }

    private var additionalMethods: [PaymentMethod] {
        let myTypes = Set(myMethods.map(\.type))
        return methods.filter { !myTypes.contains($0.type) }
    }

    private var paymentSetupIsPostSendPrompt: Bool {
        myMethods.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(ReceiptDisplay.money(amountCents))
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(tabColorHex.map { Color(hex: $0) } ?? Color.primary)
                    Text("to \(toName)")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)

                methodSelectionView
            }
            .navigationTitle("Pay \(toName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            myMethods = savedPaymentMethods()
        }
        .fullScreenCover(isPresented: $showingPaymentMethodSetup, onDismiss: {
            myMethods = savedPaymentMethods()
        }) {
            PaymentMethodView(
                onBack: {
                    showingPaymentMethodSetup = false
                },
                onRequestExpand: {},
                onSaved: {
                    myMethods = savedPaymentMethods()
                    showingPaymentMethodSetup = false
                },
                isPostSendPrompt: paymentSetupIsPostSendPrompt
            )
        }
    }

    @ViewBuilder
    private var methodSelectionView: some View {
        VStack(spacing: 0) {
            Text("Selecting a payment method will automatically send a confirmation to this chat.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if myMethods.isEmpty && mutualMethods.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Set up your payment methods first")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.primary)

                                Text("Add your payment methods to see the shared options for paying \(toName).")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button("Set Up Payment Methods") {
                                    showingPaymentMethodSetup = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(16)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Payment Options")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)

                                if mutualMethods.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("No shared payment methods")
                                            .font(.system(size: 17, weight: .semibold))
                                        Text("Edit your payment methods to match one of \(toName)'s supported options.")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                } else {
                                    paymentMethodList(mutualMethods)
                                }
                            }

                            if !additionalMethods.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("\(toName) Supports")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.secondary)

                                    supportedMethodsGrid(additionalMethods)

                                    Button {
                                        showingPaymentMethodSetup = true
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "creditcard.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.primary)
                                            Text("Edit Payment Methods")
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 16)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func supportedMethodsGrid(_ methods: [PaymentMethod]) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            ForEach(methods, id: \.id) { method in
                HStack(spacing: 8) {
                    Image(systemName: method.type.iconName)
                        .font(.system(size: 16))
                    Text(method.type.displayName)
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
        }
    }

    @ViewBuilder
    private func paymentMethodList(_ methods: [PaymentMethod]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                Button {
                    onSelectMethod(method)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: method.type.iconName)
                            .font(.system(size: 22))
                            .frame(width: 36)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.type.displayName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                            if !method.identifier.isEmpty {
                                Text(method.identifier)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < methods.count - 1 {
                    Divider().padding(.leading, 70)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

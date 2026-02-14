//
//  DefaultsKeys.swift
//  Loot
//
//  Created by Joshua Liu on 1/5/26.
//


import Foundation

enum DefaultsKeys {
    static let myDisplayName = "my_display_name"
    static let localParticipantId = "local_participant_id"
    static let conversationTabMap = "conversation_tab_map"
    static let paymentMethods = "payment_methods"
}

func myDisplayNameFromDefaults() -> String {
    return (UserDefaults.standard.string(forKey: DefaultsKeys.myDisplayName) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func savedPaymentMethods() -> [PaymentMethod] {
    guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.paymentMethods) else { return [] }
    return (try? JSONDecoder().decode([PaymentMethod].self, from: data)) ?? []
}

func savePaymentMethodsToDefaults(_ methods: [PaymentMethod]) {
    guard let data = try? JSONEncoder().encode(methods) else { return }
    UserDefaults.standard.set(data, forKey: DefaultsKeys.paymentMethods)
}

func hasPaymentMethodsConfigured() -> Bool {
    guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.paymentMethods),
          let methods = try? JSONDecoder().decode([PaymentMethod].self, from: data)
    else { return false }
    return !methods.isEmpty
}

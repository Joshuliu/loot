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
}

func myDisplayNameFromDefaults() -> String {
    return (UserDefaults.standard.string(forKey: DefaultsKeys.myDisplayName) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

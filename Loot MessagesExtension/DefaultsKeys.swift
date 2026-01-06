//
//  DefaultsKeys.swift
//  Loot
//
//  Created by Joshua Liu on 1/5/26.
//


import Foundation

enum DefaultsKeys {
    static let myDisplayName = "my_display_name"
}

func myDisplayNameFromDefaults() -> String {
    return (UserDefaults.standard.string(forKey: DefaultsKeys.myDisplayName) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

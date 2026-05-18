//
//  AppCoordinator.swift
//  Loot MessagesExtension
//
//  Phase 3 step 15: routing + presentation state. Replaces the last two
//  fields on the now-deleted `LootUIModel`:
//    - `currentScreen` (with the screen-transition logging didSet)
//    - `isExpanded` (compact vs expanded presentation style)
//
//  All other LootUIModel fields have already been migrated:
//    - In-flight bill state → ReceiptDraftViewModel
//    - Opened-bubble state → MessageReceiptViewModel
//    - Tab/conversation state → TabContextViewModel
//    - UIKit-bridge closures → MessageBus protocol
//
//  After this step lands, `LootUIModel` no longer exists. Views observe
//  this coordinator for screen routing, the three feature VMs for their
//  state, and inject `MessageBus` for UIKit bridging.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {

    /// Compact vs expanded presentation style. Tracked here so SwiftUI
    /// views can react to iMessage's transition animations without
    /// holding a reference to `MSMessagesAppViewController`.
    @Published var isExpanded: Bool = false

    /// Active screen. The didSet logs all transitions; the `messageViewer
    /// → tabview` transition is specifically called out because it has
    /// historically been the smoking gun for "click a receipt to open it
    /// but lands on .tabview instead" bugs.
    @Published var currentScreen: AppScreen = .tabview {
        didSet {
            guard oldValue != currentScreen else { return }
            print("[Screen] \(oldValue) -> \(currentScreen)")
            // Stack trace only for the specific bug under investigation:
            // "click a receipt to open it but lands on .tabview instead."
            // Captures any unexpected reversion to .tabview right after a
            // navigation away from it.
            if currentScreen == .tabview && oldValue == .messageViewer {
                print("[Screen] WARN: .messageViewer -> .tabview — call stack:")
                Thread.callStackSymbols.prefix(12).forEach { print("[Screen]   \($0)") }
            }
        }
    }
}

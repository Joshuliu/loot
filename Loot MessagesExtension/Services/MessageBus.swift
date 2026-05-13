//
//  MessageBus.swift
//  Loot MessagesExtension
//
//  Phase 3 step 13b: protocol that wraps the UIKit-bridge closures that
//  used to live on `LootUIModel`. ViewModels and SwiftUI views depend on
//  this protocol, never on the concrete `MSMessagesAppViewController`.
//
//  The concrete implementation lives in `MessagesViewController+MessageBus.swift`
//  and routes each call to the corresponding `sendX*Message` helper on the
//  view controller, which has access to `activeConversation`,
//  `extensionContext`, and the bill-update session anchors.
//
//  Why a protocol: the views previously held optional closures
//  (`uiModel.sendBillUpdate?`, `uiModel.openInSafari`) that the controller
//  had to set up at runtime in `viewDidLoad`. Five closures with five
//  call-site `?` checks was clunky and meant any null-pointer slip would
//  silently drop a send. A protocol gives compile-time visibility of the
//  full surface area, and the concrete `weak`-referenced implementation
//  on the controller continues to work the same way.
//
//  Caller side: views inject `let bus: MessageBus` and call `bus.send*`
//  directly. The methods are non-optional — if you have a bus, you can
//  call it. The `weak` in the implementation handles controller
//  deallocation gracefully (the methods become no-ops if the controller
//  goes away).
//

import Foundation

/// UIKit-bridge surface that lets feature views send messages, open URLs,
/// and broadcast bill updates without holding a reference to the
/// `MSMessagesAppViewController` directly.
@MainActor
protocol MessageBus: AnyObject {

    /// Opens a URL in Safari via the extension context. Used for payment
    /// deep links (Venmo, Zelle, etc.) that need to leave iMessage.
    func openInSafari(_ url: URL)

    /// Sends a styled settlement card into the active iMessage conversation.
    /// Args: (fromName, toName, amountCents, methodName, tabColorHex)
    func sendSettlementCard(
        fromName: String,
        toName: String,
        amountCents: Int,
        methodName: String,
        tabColorHex: String?
    )

    /// Apple Pay handoff: sends a settlement card AND inserts a how-to card
    /// into the compose tray with a shared MSSession, so the user can either
    /// open the Apple Cash drawer (and the how-to is harmlessly dropped) or
    /// hit send on the how-to (which replaces the settlement card in chat).
    func sendApplePayHandoff(
        fromName: String,
        toName: String,
        amountCents: Int,
        tabColorHex: String?
    )

    /// Inserts a payment-request card into the iMessage draft box (user
    /// presses Send to actually broadcast).
    func sendRequestCard(
        creditorName: String,
        debtorName: String,
        amountCents: Int,
        tabColorHex: String?,
        metadata: RequestCardMetadata?
    )

    /// Sends an updated live receipt card on the current session so iMessage
    /// replaces the bubble in place (retract+replace). Args: (payload,
    /// Firestore docId, action that triggered the update).
    func sendBillUpdate(
        payload: LootMessagePayload,
        docId: String,
        action: BillUpdateAction
    )
}

# Loot

Loot is an iMessage-native bill splitting app built for the messy part of group spending: scanning receipts, splitting costs, tracking who owes what, and getting paid without leaving the conversation.

The app is centered around a Messages extension, so a receipt can live inside the chat where the expense actually happened. Someone scans or uploads a receipt, Loot parses it, turns it into a shared card, and everyone in the thread can open the same receipt state to claim their spot, review items, see what they owe, and settle up.

## What Loot does

- Scan or upload receipts directly from iMessage
- Parse receipt totals, taxes, fees, discounts, and items
- Split bills evenly, by custom amounts, or by items
- Let people claim themselves on a receipt after it is sent
- Create shared Loot Tabs for recurring group spending
- Track tab balances and settlements inside the conversation
- Support payment methods so people only see useful ways to pay
- Render receipt cards and tab cards directly inside Messages

## Core idea

Loot is trying to make splitting a receipt feel like continuing the conversation, not switching into a separate finance app. The chat already has the group, the context, and the moment someone says “who had what?” Loot keeps the bill there.

## Project structure

- `Loot/`: main iOS app target
- `Loot MessagesExtension/`: iMessage extension and most of the shared product logic
- `Loot MessagesExtension/Features/Receipt/`: receipt capture, OCR, parsing, and editing
- `Loot MessagesExtension/Features/Split/`: split logic, claiming, and receipt summary flows
- `Loot MessagesExtension/Features/Tab/`: shared tabs, balances, invites, and settle-up flows
- `Loot MessagesExtension/Features/Payment/`: payment methods and pay-now flows

## Tech notes

- SwiftUI UI layered inside `MSMessagesAppViewController`
- Firestore-backed shared receipt and tab state
- Receipt capture and OCR / parsing pipeline for turning images into editable receipt data
- Message payloads that let Loot cards open with shared state inside iMessage

## Links

- Website: [plsloot.me](https://plsloot.me/)
- Instagram: [@plsloot.me](https://instagram.com/plsloot.me)


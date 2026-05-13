# Loot — Codebase Reference

iMessage extension app for splitting bills and managing group tabs. SwiftUI + Firebase (Firestore + Anonymous Auth) + Gemini AI for OCR.

**Target directory:** `Loot MessagesExtension/`
**Do NOT run xcodebuild** — user builds via Xcode to a physical device.

---

## Naming Conventions

- `LootTab` (not `Tab`) — avoids conflict with SwiftUI's `Tab` type
- `LootTabView` (not `TabView`) — avoids conflict with SwiftUI's `TabView`
- `LootTab.id` is `String?` (`@DocumentID`) — use `tab.id ?? ""` when a non-optional String is needed
- `TabReceipt` (not `Receipt`) — receipt stored inside a tab
- `ReceiptDisplay` — UI-layer model (not Firestore-backed)

---

## File Map

```
Loot MessagesExtension/
├── Core/
│   ├── MessagesViewController.swift   — UIKit entry point; message send/receive; SplitMath enum
│   ├── RootContainerView.swift        — SwiftUI root; screen switching; session save/restore
│   ├── ReceiptDisplay.swift           — ReceiptDisplay, ParsedReceipt, LootUIModel, LoadingState, AppScreen
│   └── SessionPersistence.swift       — Persists active screen/receipt across reopens
│
├── Services/
│   └── SharedReceiptService.swift     — Firestore CRUD for sharedReceipts collection
│
├── Models/
│   └── TabModels.swift                — All Firestore models: LootTab, TabMember, TabReceipt,
│                                        ReceiptSplit, Settlement, LootUser, PaymentMethod(Type)
│
├── Utilities/
│   ├── LootMessagePayload.swift       — Message transport: LootMessagePayload, ReceiptPayload,
│   │                                    SplitPayload, TabPayload, LootMessageCodec
│   ├── MoneyHelpers.swift             — stringToCents(), centsToDecimalString()
│   ├── KeychainHelper.swift           — KeychainHelper.getOrCreateUserId()
│   └── DefaultsKeys.swift             — DefaultsKeys enum, myDisplayNameFromDefaults(),
│                                        savedPaymentMethods(), savePaymentMethodsToDefaults()
│
├── Features/
│   ├── Receipt/
│   │   ├── Analysis/LLMClient.swift          — Gemini API; parsePhase1(), parsePhase2()
│   │   ├── Processing/OCRTypes.swift         — OCRResult, OCRBlock, OCRWord, OCRBoundingBox
│   │   ├── Processing/LegacyOCRPipeline.swift— straightenImage(), runVisionKitOCR(), cropToOCRBounds()
│   │   ├── Processing/TranscriptGenerator.swift — OCR → structured text
│   │   ├── Processing/ReceiptCrop.swift       — Receipt region detection/cropping
│   │   ├── Processing/DebugOCRView.swift      — Debug OCR visualization
│   │   ├── Capture/CameraPicker.swift         — Camera capture sheet
│   │   ├── Capture/PhotoLibraryPicker.swift   — Photo library picker
│   │   ├── Capture/CustomCameraView.swift     — Custom camera UI fallback
│   │   └── Views/
│   │       ├── ReceiptView.swift              — Itemized receipt display
│   │       ├── EditReceiptView.swift          — Edit receipt fields after scan
│   │       ├── ManualInputView.swift          — Manual entry (no camera)
│   │       ├── TipView.swift                  — Tip input screen
│   │       └── MessageReceiptViewer.swift     — View a tapped Loot message
│   │
│   ├── Split/
│   │   ├── SplitView.swift            — SplitDraft, SplitGuest, CentSlider, DonutDrag
│   │   ├── EditSplitView.swift        — Post-send split editor (Payload ↔ Draft)
│   │   ├── SplitGuestEditor.swift     — Individual guest name/inclusion editing
│   │   ├── SplitsSummaryView.swift    — Per-person split summary with ring donut
│   │   └── DebtSimplifier.swift       — Settle-up algorithm (debt chain optimization)
│   │
│   ├── Tab/
│   │   ├── TabView.swift              — LootTabView; compact + expanded modes; balance display
│   │   ├── TabService.swift           — TabService.shared; all tab Firestore ops
│   │   ├── TabBalanceTests.swift      — Balance computation debug tests
│   │   └── Views/
│   │       ├── NewTabView.swift               — Create tab (name + color)
│   │       ├── JoinTabView.swift              — Join tab via invite
│   │       ├── TabSettingsView.swift          — Edit tab (name, color, members)
│   │       ├── TabSettleUpCard.swift          — Settlement card (who owes whom)
│   │       └── TabInviteConfirmationView.swift— Confirm joining tab
│   │
│   ├── Payment/
│   │   ├── PaymentMethodView.swift    — Add/edit payment methods
│   │   ├── ZelleSetupSheet.swift      — Zelle QR code capture
│   │   └── BankPickerView.swift       — Bank selection for Zelle
│   │
│   └── Account/
│       ├── AccountView.swift          — User profile / display name editor
│       └── IntroView.swift            — Welcome / onboarding screen
│
├── Components/
│   ├── BillCardView.swift             — Message card preview: BillCardView, SettlementCardView,
│   │                                    TabInviteCardView, SplitRingView
│   ├── BillCardLoadingView.swift      — Loading skeleton for BillCardView
│   ├── ColoredCircleBadge.swift       — Person initials badge (color-coded)
│   └── CardPhysicsModifier.swift      — Card scroll physics/animation modifier
│
└── Confirmation/
    └── ConfirmationView.swift         — Final confirmation before sending; large complex view
```

---

## Key Types

### AppScreen (ReceiptDisplay.swift)
```swift
enum AppScreen {
    case tabview              // Home: tab list or empty state
    case fill                 // Manual receipt entry
    case tipview              // Add tip after scan
    case confirmation         // Final review before send
    case receipt              // View scanned/edited receipt
    case messageViewer        // View a tapped Loot message
    case newTab               // Create new tab form
    case tabInviteConfirmation
    case joinTab              // Join tab flow
    case account              // Account / display name
    case paymentMethods       // Payment method setup
}
```

### LootUIModel (ReceiptDisplay.swift) — shared ObservableObject
```swift
@Published var isExpanded: Bool
@Published var currentScreen: AppScreen
@Published var currentReceipt: ReceiptDisplay?
@Published var parsedReceipt: ParsedReceipt?
@Published var scanImageOriginal, scanImageCropped: UIImage?
@Published var currentSplitDraft: SplitDraft?
@Published var openedMessagePayload: LootMessagePayload?
@Published var openedMessageDocId: String?
@Published var messageLoadingState: LoadingState<LootMessagePayload>
@Published var itemsLoadingState: LoadingState<Phase2Result>
@Published var preTipTotalOverrideCents: Int?
@Published var activeTab: LootTab?
@Published var receiptTab: LootTab?
@Published var userTabs: [LootTab]
@Published var conversationKey, pendingTabInviteId: String?
@Published var conversationMemberIds: Set<String>
var openInSafari: ((URL) -> Void)?
var sendSettlementCard: ((String, String, Int, String, String?) -> Void)?
var sendRequestCard: ((String, String, Int, String?) -> Void)?
```

### LootTab (TabModels.swift)
```swift
struct LootTab: Codable, Identifiable {
    @DocumentID var id: String?
    let name: String
    let colorHex: String?
    let createdBy: String       // userId
    let status: TabStatus       // active | settled
    var members: [TabMember]
    var memberIds: [String]
    var receiptCount: Int
    @ServerTimestamp var createdAt, updatedAt: Timestamp?
}
```

### TabMember (TabModels.swift)
```swift
struct TabMember: Codable, Identifiable {
    let memberId: String
    let userId: String?
    let displayName: String
    var balanceCents: Int       // positive = owed money, negative = owes money
    var isActive: Bool
    var id: String { memberId }
}
```

### TabReceipt (TabModels.swift)
```swift
struct TabReceipt: Codable, Identifiable {
    @DocumentID var id: String?
    let title: String
    let createdBy: String
    @ServerTimestamp var createdAt: Timestamp?
    let totalCents, subtotalCents, taxCents, tipCents, feesCents, discountCents: Int
    let splitMode: SplitMode    // equally | byItems | custom
    let payerMemberId: String
    let splits: [ReceiptSplit]
    let items: [ReceiptItem]?
    let imageUrl: String?
    let messagePayloadId: String?
}
```

### SplitDraft (SplitView.swift) — working split state in UI
```swift
struct SplitDraft: Equatable, Codable {
    enum Mode: String, CaseIterable, Codable { case equally, byItems, custom }
    var guests: [SplitGuest]
    var payerGuestId: UUID
    var mode: Mode
    var totalCents: Int
    var perGuestCents: [Int]
    var items: [Item]
    var feesCents, taxCents, tipCents, discountCents: Int
}

struct SplitGuest: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isIncluded: Bool
    var isMe: Bool
    var uid: String?            // Keychain UUID if known
}
```

### LootMessagePayload (LootMessagePayload.swift) — URL transport format
```swift
struct LootMessagePayload: Codable {
    var v: Int = 1
    let r: ReceiptPayload
    let s: SplitPayload
    let tid: String?            // tabId
    let trid: String?           // tabReceiptId
    let tab: TabPayload?
    let su: String?             // senderUid
}
// Encoded via LootMessageCodec: Base64URL + LZFSE compression
```

### PaymentMethod (TabModels.swift)
```swift
struct PaymentMethod: Codable, Identifiable, Equatable {
    let type: PaymentMethodType // venmo | zelle | cashapp | paypal | applePay | cash
    let identifier: String
    let bankName, bankURL, zelleData: String?
}
```

---

## Services

### SharedReceiptService.shared (Services/SharedReceiptService.swift)
- `configureFirebaseIfNeeded()` — static, called in MessagesViewController.viewDidLoad
- `ensureAnonymousAuth()` — ensures Firebase anonymous auth token is valid
- `generateDocId() -> String` — creates pre-generated Firestore doc ID
- `upload(_ payload:, captureImage:, docId:)` — writes to `sharedReceipts/[docId]`
- `fetch(id:) -> (LootMessagePayload, UIImage?)` — reads from Firestore
- `updatePayload(_ payload:, docId:)` — merge-updates existing doc

### TabService.shared (Features/Tab/TabService.swift)
**Tab CRUD:**
- `createTab(name:colorHex:conversationKey:) -> LootTab`
- `joinTab(tabId:conversationKey:) -> LootTab`
- `fetchTab(id:) -> LootTab?`
- `fetchUserTabs() -> [LootTab]`
- `updateTab(_ tab:)`
- `leaveTab(tabId:)`
- `deleteTab(tabId:)`

**Conversation mapping:**
- `conversationKey(from: [String]) -> String` — SHA256 hash of sorted participant UUIDs
- `associateConversation(tabId:conversationKey:)`
- `getTabForConversation(conversationKey:) -> LootTab?`
- `removeConversationMapping(conversationKey:)`

**Caching:**
- `cachedTab(for conversationKey:) -> LootTab?`
- `cacheTab(_ tab:, for conversationKey:)`

**Receipts & Settlements:**
- `addReceipt(_ receipt:, toTab:) -> String`
- `updateReceipt(_ receipt:, inTab:, receiptId:)`
- `recordSettlement(_ settlement:, forTab:)`
- `fetchReceipts(forTab:) -> [TabReceipt]`
- `fetchSettlements(forTab:) -> [Settlement]`
- `computeTabBalances(tabId:members:) -> [String: Int]`

**Users & Payments:**
- `createOrUpdateUser(userId:displayName:)`
- `fetchUserDisplayName(userId:) -> String?`
- `updatePaymentMethods(userId:methods:)`
- `fetchPaymentMethods(userId:) -> [PaymentMethod]?`

### LLMClient.shared (Features/Receipt/Analysis/LLMClient.swift)
- `parsePhase1(image: UIImage) -> Phase1Result` — merchant, total from image
- `parsePhase2(ocrResult:ocrTranscript:phase1:) -> Phase2Result` — itemized breakdown
- Uses Gemini 2.5 Flash Lite REST API

---

## Navigation Flow

```
MessagesViewController (UIKit host)
    └── RootContainerView (SwiftUI, switches on AppScreen)
        ├── .tabview   → LootTabView
        ├── .fill      → ManualInputView
        ├── .tipview   → TipView
        ├── .receipt   → ReceiptView + EditReceiptView
        ├── .confirmation → ConfirmationView
        ├── .messageViewer → MessageReceiptViewer
        ├── .newTab    → NewTabView
        ├── .joinTab   → JoinTabView
        ├── .account   → AccountView
        └── .paymentMethods → PaymentMethodView
```

**Message URL parsing (MessagesViewController.applyMessage):**
- `?id=<docId>` → fetch Firestore → `.messageViewer`
- `?tabInvite=<tabId>` → fetchTab → `.joinTab`
- `?tabId=<id>&tn=<name>&tc=<hex>` → load tab for settlement message

---

## Data Flow

### Scan → Send
```
Camera/Photo → LegacyOCRPipeline (VisionKit) → OCRResult
    → LLMClient.parsePhase1() + parsePhase2() → ParsedReceipt
    → EditReceiptView (user edits) → TipView
    → SplitView (SplitDraft built) → ConfirmationView
    → sendBillMessage():
        LootMessageCodec.encodeToQueryValue() → URL "p" param
        SharedReceiptService.upload() → Firestore sharedReceipts/[docId]
        (if activeTab) TabService.addReceipt() → updates member balances
        MSMessage sent to conversation
```

### Receive & View Message
```
Message tapped → applyMessage(url)
    → SharedReceiptService.fetch(docId) → LootMessagePayload + UIImage
    → payload.toReceiptDisplay() → ReceiptDisplay
    → MessageReceiptViewer → ReceiptView
    (if canEdit) → EditSplitView (SplitPayload ↔ SplitDraft)
    → SharedReceiptService.updatePayload() → Firestore merge
```

### Tab Create / Join
```
NewTabView → TabService.createTab() → Firestore tabs/[tabId]
    → TabService.associateConversation() → Firestore conversationTabs/[key]
    → uiModel.activeTab set

?tabInvite → TabService.fetchTab() → JoinTabView
    → TabService.joinTab() → adds TabMember → conversationTabs updated
    → uiModel.activeTab set
```

---

## Firestore Schema

```
sharedReceipts/[docId]     — r, s, tid, trid, tab, su, _captureImage (base64 JPEG)
tabs/[tabId]               — name, colorHex, createdBy, status, members[], memberIds[], receiptCount
tabs/[tabId]/receipts/[id] — title, splits[], items[], splitMode, payerMemberId, amounts
tabs/[tabId]/settlements/[id] — fromMemberId, toMemberId, amountCents, note
users/[userId]             — displayName, paymentMethods[]
conversationTabs/[convKey] — tabId, updatedAt
```

---

## Utilities

| Function | File | Purpose |
|----------|------|---------|
| `stringToCents(_ raw:)` | MoneyHelpers.swift | "$12.50" → 1250 |
| `centsToDecimalString(_ cents:)` | MoneyHelpers.swift | 1250 → "12.50" |
| `myDisplayNameFromDefaults()` | DefaultsKeys.swift | Reads display name from UserDefaults |
| `savedPaymentMethods()` | DefaultsKeys.swift | Reads [PaymentMethod] from UserDefaults |
| `KeychainHelper.getOrCreateUserId()` | KeychainHelper.swift | Stable UUID, created on first call |
| `LootMessageCodec.encodeToQueryValue()` | LootMessagePayload.swift | Payload → Base64URL+LZFSE string |
| `LootMessageCodec.payload(from: url)` | LootMessagePayload.swift | URL → LootMessagePayload |
| `SessionPersistence.save/load/clear()` | SessionPersistence.swift | Persist screen state across reopens |
| `SplitMath.computeOwedCents(...)` | MessagesViewController.swift | equally/custom/byItems split math |
| `TabService.conversationKey(from:)` | TabService.swift | SHA256 of sorted participant UUIDs |
| `BadgeColors.color(for: slotIndex)` | (ColoredCircleBadge.swift) | Color per guest slot index |
| `TabColorOptions.all` | (NewTabView or TabModels) | Preset hex colors for tabs |

---

## Architecture Notes

- **No login flow** — identity is Keychain UUID + Firebase Anonymous Auth
- **Display name** — set in `IntroView`, stored in `@AppStorage(DefaultsKeys.myDisplayName)`
- **iMessage expansion** — `uiModel.isExpanded` tracks compact vs expanded mode
- **Session persistence** — `SessionPersistence` saves `.confirmation/.fill/.tipview/.receipt` across app reopens; tab screens are NOT persisted
- **Xcode auto-discovers Swift files** — no pbxproj edits needed for new files
- **URL size limit** — MSMessage URL ~2000 chars; payload compressed with LZFSE to fit
- **Split modes:** `equally` (even split), `custom` (manual per-person), `byItems` (item assignment)
- `balanceCents` on `TabMember`: positive = this person is owed money, negative = this person owes money

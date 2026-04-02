/**
 * Firestore Migration: Fold discountCents into feesCents
 *
 * For every TabReceipt document that has discountCents > 0:
 *   - feesCents = feesCents - discountCents  (discount becomes negative fees)
 *   - discountCents field is deleted
 *
 * Run with:
 *   node migrate-discounts.js
 *
 * Requires:
 *   npm install firebase-admin
 *   Set GOOGLE_APPLICATION_CREDENTIALS env var to your service account JSON, OR
 *   place serviceAccountKey.json next to this script.
 */

const admin = require("firebase-admin");

// Initialize — uses GOOGLE_APPLICATION_CREDENTIALS env var if set, else service account file
let serviceAccount;
try {
  serviceAccount = require("./serviceAccountKey.json");
} catch (_) {}

if (serviceAccount) {
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
} else {
  admin.initializeApp({ credential: admin.credential.applicationDefault() });
}

const db = admin.firestore();

async function migrate() {
  console.log("Starting discountCents → feesCents migration...\n");

  const tabsSnap = await db.collection("tabs").get();
  let tabCount = 0;
  let receiptCount = 0;
  let migratedCount = 0;

  for (const tabDoc of tabsSnap.docs) {
    tabCount++;
    const receiptsSnap = await tabDoc.ref.collection("receipts").get();

    for (const receiptDoc of receiptsSnap.docs) {
      receiptCount++;
      const data = receiptDoc.data();

      // Only migrate docs that have a non-zero discountCents field
      if (
        data.discountCents !== undefined &&
        data.discountCents !== null &&
        data.discountCents !== 0
      ) {
        const oldFees = data.feesCents ?? 0;
        const discount = data.discountCents;
        const newFees = oldFees - discount;

        console.log(
          `  Tab ${tabDoc.id} / Receipt ${receiptDoc.id}: ` +
            `feesCents ${oldFees} → ${newFees} (discount was ${discount})`
        );

        await receiptDoc.ref.update({
          feesCents: newFees,
          discountCents: admin.firestore.FieldValue.delete(),
        });

        migratedCount++;
      } else if (data.discountCents === 0 || data.discountCents === null) {
        // Just remove the zero/null discountCents field to clean up
        await receiptDoc.ref.update({
          discountCents: admin.firestore.FieldValue.delete(),
        });
      }
    }
  }

  console.log(`\nDone. Scanned ${tabCount} tabs, ${receiptCount} receipts.`);
  console.log(`Migrated ${migratedCount} receipts with non-zero discounts.`);
}

migrate().catch((err) => {
  console.error("Migration failed:", err);
  process.exit(1);
});

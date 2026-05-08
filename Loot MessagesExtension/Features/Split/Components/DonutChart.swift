//
//  DonutChart.swift
//  Loot
//
//  Donut visualization used by the split editor's "equal" and "custom" panels.
//  Extracted from SplitView.swift in Phase 4.
//
//  Owns its own drag-tracking state (`DonutDrag`, `haptic`, `lastHapticCents`)
//  so callers don't have to thread that machinery. Math (sumBefore/sumThrough/
//  remainingExcluding/lastActiveIndex/colorForActiveIdx) is provided as
//  closures because the canonical source is the split editor; this view just
//  paints the result.
//
import SwiftUI

struct DonutChart: View {
    // Data
    let activeCount: Int
    let totalCents: Int
    let interactive: Bool        // false for equal mode (drag handle hidden)
    let isEqualMode: Bool        // dim drag handle in equal mode

    // Selection
    @Binding var selectedIndex: Int
    @Binding var guestAmountsCents: [Int]
    @Binding var fineTunerScrollTarget: Int?

    // Center label (precomputed by caller)
    let centerName: String
    let centerMoneyParts: (String, String)
    let centerPercent: String
    let isEditingCenterAmount: Bool

    // Color + math callbacks (keeps split-editor as the source of truth)
    let colorForActiveIdx: (Int) -> Color
    let sumBefore: (Int) -> Int
    let sumThrough: (Int) -> Int
    let lastActiveIndex: (Int) -> Int
    let remainingExcluding: (Int) -> Int

    let onTapEditAmount: () -> Void

    // Drag state — fully internal; callers get the resulting cents via
    // `guestAmountsCents` binding and the post-drag scroll target via
    // `fineTunerScrollTarget`.
    @State private var donutDrag: DonutDrag? = nil
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticCents: Int = 0

    private struct DonutDrag {
        var lastRawFrac: Double
        var endFracUnwrapped: Double
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, 210)
            let lineW: CGFloat = 30
            let radius = size / 2 - lineW / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let handleRadius = radius + lineW / 2

            ZStack {
                Circle()
                    .stroke(Color(.secondarySystemBackground),
                            style: .init(lineWidth: lineW, lineCap: .round))
                    .frame(width: size, height: size)

                ForEach(0..<activeCount, id: \.self) { i in
                    if totalCents > 0, guestAmountsCents.count == activeCount {
                        let startFrac = Double(sumBefore(i)) / Double(totalCents)
                        let endFrac = Double(sumThrough(i)) / Double(totalCents)
                        if endFrac > startFrac {
                            Circle()
                                .trim(from: startFrac, to: endFrac)
                                .stroke(colorForActiveIdx(i),
                                        style: .init(lineWidth: lineW, lineCap: .round))
                                .opacity(1)
                                .rotationEffect(.degrees(-90))
                                .frame(width: size, height: size)
                                .overlay(
                                    Circle()
                                        .trim(from: startFrac, to: endFrac)
                                        .stroke(Color.black.opacity(0.001),
                                                style: .init(lineWidth: lineW * 4.5,
                                                             lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: size, height: size)
                                )
                                .onTapGesture {
                                    guard interactive else { return }
                                    selectedIndex = i
                                }
                        }
                        // Show divider circle only if previous guest has amount > $0
                        let colorIdx = lastActiveIndex(i)
                        if i > 0 {
                            let ang = -(.pi / 1.975) + (startFrac * 2 * .pi)
                            let hx = center.x + handleRadius * cos(ang)
                            let hy = center.y + handleRadius * sin(ang)

                            Circle()
                                .fill(colorForActiveIdx(colorIdx))
                                .overlay(
                                    Circle().stroke(colorForActiveIdx(colorIdx), lineWidth: 0.05)
                                )
                                .frame(width: 30, height: 30)
                                .position(x: hx, y: hy)
                        }
                    }
                }

                if totalCents > 0,
                   guestAmountsCents.count == activeCount,
                   activeCount > 0 {

                    let startFrac = Double(sumBefore(selectedIndex)) / Double(totalCents)
                    let endFrac = Double(sumThrough(selectedIndex)) / Double(totalCents)
                    let handleFrac = max(startFrac, endFrac)
                    let ang = (handleFrac * 2 * .pi) - (.pi / 2)

                    let hx = center.x + handleRadius * cos(ang)
                    let hy = center.y + handleRadius * sin(ang)

                    Circle()
                        .fill(colorForActiveIdx(selectedIndex))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(.white, lineWidth: 5))
                        .position(x: hx, y: hy)
                        .contentShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard interactive else { return }
                                    guard totalCents > 0 else { return }

                                    let p = value.location
                                    let dx = p.x - center.x
                                    let dy = p.y - center.y

                                    var a = atan2(dy, dx) + (.pi / 2)
                                    if a < 0 { a += 2 * .pi }
                                    let rawFrac = a / (2 * .pi)

                                    let startFrac = Double(sumBefore(selectedIndex)) / Double(totalCents)
                                    let maxAlloc = remainingExcluding(selectedIndex)
                                    let maxEnd = startFrac + Double(maxAlloc) / Double(totalCents)

                                    if donutDrag == nil {
                                        let curEnd = Double(sumThrough(selectedIndex)) / Double(totalCents)
                                        donutDrag = DonutDrag(lastRawFrac: rawFrac, endFracUnwrapped: curEnd)
                                        haptic.prepare()
                                    }

                                    var d = donutDrag!
                                    var delta = rawFrac - d.lastRawFrac
                                    if delta > 0.5 { delta -= 1 }
                                    if delta < -0.5 { delta += 1 }
                                    d.lastRawFrac = rawFrac
                                    d.endFracUnwrapped += delta

                                    let endClamped = min(max(d.endFracUnwrapped, startFrac), maxEnd)
                                    donutDrag = d

                                    var newCents = Int(round((endClamped - startFrac) * Double(totalCents)))
                                    newCents = min(max(newCents, 0), maxAlloc)
                                    let centsDiff = abs(newCents - lastHapticCents)

                                    if centsDiff >= totalCents/100 {
                                        haptic.impactOccurred(intensity: 7.0)
                                        lastHapticCents = newCents
                                        haptic.prepare()
                                    }

                                    guestAmountsCents[selectedIndex] = newCents
                                }
                                .onEnded { _ in
                                    let finalCents = guestAmountsCents.indices.contains(selectedIndex)
                                        ? guestAmountsCents[selectedIndex]
                                        : 0
                                    fineTunerScrollTarget = finalCents
                                    donutDrag = nil
                                }
                        )
                        .animation(nil, value: handleFrac)
                        .opacity(isEqualMode ? 0 : 1)
                }

                VStack(spacing: 4) {
                    Text("\(centerName) pays")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(centerMoneyParts.0)
                            .font(.system(size: 30, weight: .bold))
                        Text(centerMoneyParts.1)
                            .font(.system(size: 30, weight: .bold))
                    }
                    .opacity(isEditingCenterAmount ? 0 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTapEditAmount()
                    }

                    Text(centerPercent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 220)
    }
}

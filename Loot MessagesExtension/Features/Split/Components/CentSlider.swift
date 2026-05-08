//
//  CentSlider.swift
//  Loot
//
//  Fine-tuner control used (today commented out) under the split donut.
//  Extracted from SplitView.swift in Phase 4.
//
import SwiftUI

struct CentSlider: View {
    @Binding var cents: Int
    let maxCents: Int
    let color: Color
    let isDraggingDonut: Bool
    @Binding var scrollTarget: Int?

    @State private var dragStartCents: Int? = nil
    @State private var viewWidth: CGFloat = 300
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticCents: Int = 0

    private let pxPerCent: CGFloat = 3.0
    private let majorTickSpacing = 25
    private let labelSpacing = 50

    private var displayOffset: CGFloat {
        -CGFloat(cents) * pxPerCent
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack {
                Canvas { context, size in
                    drawTicks(context: context, size: size, offset: displayOffset)
                }

                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard !isDraggingDonut else { return }

                        if dragStartCents == nil {
                            dragStartCents = cents
                            haptic.prepare()
                        }

                        let startCents = dragStartCents ?? cents
                        let deltaCents = Int(round(-value.translation.width / pxPerCent))
                        let newCents = min(max(startCents + deltaCents, 0), maxCents)

                        if newCents != cents {
                            cents = newCents

                            if abs(newCents - lastHapticCents) >= 25 {
                                haptic.impactOccurred(intensity: 0.4)
                                lastHapticCents = newCents
                            }
                        }
                    }
                    .onEnded { _ in
                        dragStartCents = nil
                        lastHapticCents = cents
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard !isDraggingDonut else { return }

                        let tapX = value.location.x
                        let centerX = width / 2
                        let offsetFromCenter = tapX - centerX
                        let tappedCents = cents + Int(round(offsetFromCenter / pxPerCent))

                        let snappedCents = Int(round(Double(tappedCents) / Double(majorTickSpacing))) * majorTickSpacing
                        let clampedCents = min(max(snappedCents, 0), maxCents)

                        withAnimation(.easeOut(duration: 0.2)) {
                            cents = clampedCents
                        }
                        haptic.impactOccurred(intensity: 0.5)
                        lastHapticCents = clampedCents
                    }
            )
            .onAppear {
                viewWidth = width
                lastHapticCents = cents
            }
            .onChange(of: scrollTarget) { _, newTarget in
                guard let target = newTarget else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    cents = min(max(target, 0), maxCents)
                }
                lastHapticCents = cents
                scrollTarget = nil
            }
            .onChange(of: geo.size.width) { _, newWidth in
                viewWidth = newWidth
            }
        }
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawTicks(context: GraphicsContext, size: CGSize, offset: CGFloat) {
        let trackY = size.height / 2
        let effectiveMax = max(100, maxCents)

        let visibleStartCents = Int(max(0, (-offset - size.width) / pxPerCent))
        let visibleEndCents = Int(min(Double(effectiveMax), (-offset + size.width) / pxPerCent))

        let tickSpacing = 5
        let startTick = max(0, (visibleStartCents / tickSpacing) * tickSpacing)
        for c in stride(from: startTick, through: min(visibleEndCents, effectiveMax), by: tickSpacing) {
            if c % labelSpacing == 0 { continue }

            let x = CGFloat(c) * pxPerCent + offset + size.width / 2
            guard x > -10 && x < size.width + 10 else { continue }

            let isMajor = c % majorTickSpacing == 0
            let tickHeight: CGFloat = isMajor ? 18 : 8
            let tickWidth: CGFloat = isMajor ? 2 : 1
            let opacity: Double = isMajor ? 0.5 : 0.25

            context.fill(
                Path(roundedRect: CGRect(x: x - tickWidth/2, y: trackY - tickHeight/2, width: tickWidth, height: tickHeight), cornerRadius: tickWidth/2),
                with: .color(.primary.opacity(opacity))
            )
        }

        let startLabel = max(0, (visibleStartCents / labelSpacing) * labelSpacing)
        for c in stride(from: startLabel, through: min(visibleEndCents, effectiveMax), by: labelSpacing) {
            let x = CGFloat(c) * pxPerCent + offset + size.width / 2
            guard x > -20 && x < size.width + 20 else { continue }

            let dollars = c / 100
            let cents = c % 100
            let isWholeDollar = cents == 0
            let labelText = isWholeDollar ? "$\(dollars)" : String(format: "$%d.%02d", dollars, cents)

            let fontSize: CGFloat = isWholeDollar ? 13 : 10
            let fontWeight: Font.Weight = isWholeDollar ? .semibold : .medium

            let resolved = context.resolve(Text(labelText).font(.system(size: fontSize, weight: fontWeight)).foregroundColor(.secondary))
            let textSize = resolved.measure(in: size)

            let bgRect = CGRect(
                x: x - textSize.width / 2 - 2,
                y: trackY - textSize.height / 2 - 1,
                width: textSize.width + 4,
                height: textSize.height + 2
            )
            context.fill(Path(roundedRect: bgRect, cornerRadius: 2), with: .color(Color(.systemBackground)))

            context.draw(resolved, at: CGPoint(x: x, y: trackY))
        }
    }
}

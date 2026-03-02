// CustomCameraView.swift
// Loot MessagesExtension

import SwiftUI
import UIKit

// MARK: - Top-level SwiftUI wrapper

/// Manages the full capture → crop → review flow.
/// The review screen is pure SwiftUI so it is never inside the
/// UIImagePickerController's view hierarchy (and therefore unaffected
/// by its cameraViewTransform).
struct CustomCameraView: View {
    @Binding var capturedImage: UIImage?
    let onCancel: () -> Void
    var onReviewImage: ((UIImage) -> Void)? = nil

    @State private var reviewImage: UIImage? = nil

    var body: some View {
        if let review = reviewImage {
            CameraReviewView(
                image: review,
                onRetake: { reviewImage = nil },
                onUse: { capturedImage = review }
            )
            .ignoresSafeArea()
        } else {
            CameraPickerView(
                onCapture: { raw in
                    let img = cropTopAndLeft(raw)
                    reviewImage = img
                    onReviewImage?(img)
                },
                onCancel: onCancel
            )
            .ignoresSafeArea()
        }
    }

    /// Receipt sits in the bottom-right of the full sensor image because the
    /// live preview was showing that region (zoomed). Crop off the top and left.
    private func cropTopAndLeft(_ image: UIImage) -> UIImage {
        let screen = UIScreen.main.bounds
        let nativeH = screen.width * (4.0 / 3.0)
        guard nativeH < screen.height else { return image }
        let zoom = screen.height / nativeH

        let W = image.size.width
        let H = image.size.height
        let outW = (W / zoom).rounded()
        let outH = (H / zoom).rounded()
        let ox = (W - outW).rounded()   // skip this much from the left
        let oy = (H - outH).rounded()   // skip this much from the top

        UIGraphicsBeginImageContextWithOptions(CGSize(width: outW, height: outH), false, image.scale)
        image.draw(at: CGPoint(x: -ox, y: -oy))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out ?? image
    }
}

// MARK: - SwiftUI review screen

private struct CameraReviewView: View {
    let image: UIImage
    let onRetake: () -> Void
    let onUse: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                Button("Retake", action: onRetake)
                    .frame(maxWidth: .infinity, minHeight: 60)
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: 36)
                Button("Use Photo", action: onUse)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .font(.system(size: 18))
            .foregroundColor(.white)
            .frame(height: 90)
            .background(Color.black.opacity(0.65))
        }
    }
}

// MARK: - UIImagePickerController wrapper (capture only)

private struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.mediaTypes = ["public.image"]

        #if targetEnvironment(simulator)
        picker.sourceType = .photoLibrary
        #else
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.cameraDevice = .rear
            picker.cameraFlashMode = .off
            picker.showsCameraControls = false

            let screen = UIScreen.main.bounds
            let nativeH = screen.width * (4.0 / 3.0)
            if nativeH < screen.height {
                let scale = screen.height / nativeH
                let dx = -(screen.width * scale - screen.width) / 2.0
                picker.cameraViewTransform = CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: dx, y: 0))
            }
            context.coordinator.setupOverlay(on: picker)
        } else {
            picker.sourceType = .photoLibrary
        }
        #endif

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPickerView
        private weak var picker: UIImagePickerController?

        init(parent: CameraPickerView) { self.parent = parent }

        func setupOverlay(on picker: UIImagePickerController) {
            self.picker = picker
            let overlay = CameraLiveOverlayView(frame: UIScreen.main.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onShutter = { [weak self] in self?.picker?.takePicture() }
            overlay.onCancel = { [weak self] in self?.parent.onCancel() }
            picker.cameraOverlayView = overlay
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let img = info[.originalImage] as? UIImage else { return }
            parent.onCapture(img)
        }
    }
}

// MARK: - Live Camera Overlay (pure UIKit — reliable touch handling)

final class CameraLiveOverlayView: UIView {
    var onShutter: (() -> Void)?
    var onCancel: (() -> Void)?

    private var receiptFrame: CGRect = .zero
    private let cancelBtn = UIButton(type: .custom)
    private let shutterBtn = UIButton(type: .custom)
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        cancelBtn.setTitle("✕", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        cancelBtn.titleLabel?.shadowColor = UIColor.black.withAlphaComponent(0.5)
        cancelBtn.titleLabel?.shadowOffset = CGSize(width: 0, height: 1)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelBtn)

        shutterBtn.backgroundColor = .white
        shutterBtn.layer.cornerRadius = 34
        shutterBtn.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        shutterBtn.layer.borderWidth = 3
        shutterBtn.clipsToBounds = true
        shutterBtn.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        addSubview(shutterBtn)

        hintLabel.text = "Align receipt within frame"
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.shadowColor = UIColor.black.withAlphaComponent(0.5)
        hintLabel.shadowOffset = CGSize(width: 0, height: 1)
        hintLabel.isUserInteractionEnabled = false
        addSubview(hintLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height

        let frameW = w * 0.78
        let frameH = h * 0.52
        let frameX = (w - frameW) / 2
        let frameY = (h - frameH) / 2 - h * 0.03
        receiptFrame = CGRect(x: frameX, y: frameY, width: frameW, height: frameH)

        cancelBtn.frame = CGRect(x: 12, y: 56, width: 60, height: 48)
        let d: CGFloat = 68
        shutterBtn.frame = CGRect(x: (w - d) / 2, y: h - d - 56, width: d, height: d)
        hintLabel.frame = CGRect(x: frameX, y: receiptFrame.maxY + 16, width: frameW, height: 24)

        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(UIColor.black.withAlphaComponent(0.48).cgColor)
        ctx.beginPath()
        ctx.addRect(rect)
        ctx.addPath(UIBezierPath(roundedRect: receiptFrame, cornerRadius: 12).cgPath)
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(UIBezierPath(roundedRect: receiptFrame, cornerRadius: 12).cgPath)
        ctx.strokePath()

        let lineCount = 5
        let spacing = receiptFrame.height / CGFloat(lineCount + 1)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [8, 6])
        for i in 1...lineCount {
            let y = receiptFrame.minY + spacing * CGFloat(i)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: receiptFrame.minX + 14, y: y))
            ctx.addLine(to: CGPoint(x: receiptFrame.maxX - 14, y: y))
            ctx.strokePath()
        }
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func shutterTapped() { onShutter?() }
}

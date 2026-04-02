import SwiftUI
import UIKit

struct CapturePreviewView: View {
    let image: UIImage?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(14)
            }

            if let image {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(Color.black.opacity(0.9))
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                Spacer()
                Text("No capture available")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color.black.opacity(0.9))
        .ignoresSafeArea()
    }
}

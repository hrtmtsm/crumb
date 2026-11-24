import SwiftUI
import UIKit

struct GuidedRecipeCamera: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        picker.cameraOverlayView = RecipeCameraGuide(frame: UIScreen.main.bounds)
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: GuidedRecipeCamera
        init(parent: GuidedRecipeCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onCapture(image)
        }
    }
}
private final class RecipeCameraGuide: UIView {
    private let instruction = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        instruction.text = AppLanguage.text("料理を丸の内側へ。端に少し余白を残して撮影")
        instruction.textAlignment = .center
        instruction.textColor = .white
        instruction.font = .systemFont(ofSize: 12, weight: .medium)
        instruction.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        instruction.layer.cornerRadius = 10
        instruction.clipsToBounds = true
        instruction.numberOfLines = 2
        addSubview(instruction)
        accessibilityLabel = AppLanguage.text("丸い料理撮影ガイド。料理を丸の内側に、余白を残して撮影してください。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let box = guideRect
        instruction.frame = CGRect(x: 22, y: min(box.maxY + 15, bounds.height - 180), width: bounds.width - 44, height: 39)
        setNeedsDisplay()
    }
    private var guideRect: CGRect {
        let side = bounds.width * 0.76
        return CGRect(x: (bounds.width - side) / 2, y: max(130, bounds.height * 0.23), width: side, height: side)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The guide never intercepts the shutter, focus taps or system camera controls.
        false
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let path = UIBezierPath(ovalIn: guideRect)
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.cgColor)
        UIColor.white.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        path.stroke()
        let center = CGPoint(x: guideRect.midX, y: guideRect.midY)
        let cross = UIBezierPath()
        cross.move(to: CGPoint(x: center.x - 7, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 7, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 7)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 7))
        cross.lineWidth = 1; UIColor.white.withAlphaComponent(0.8).setStroke(); cross.stroke()
    }
}

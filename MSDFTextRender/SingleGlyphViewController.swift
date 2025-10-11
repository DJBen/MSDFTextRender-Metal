import UIKit
import MetalKit

final class SingleGlyphViewController: UIViewController {

    private var renderer: SingleGlyphRenderer?
    private var mtkView: MTKView?
    private var zoomScale: CGFloat = 1.0
    private let minZoomScale: CGFloat = 0.5
    private let maxZoomScale: CGFloat = 20.0

    private let navigationTitle = "Single Glyph"

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = navigationTitle
        configureNavigationBar()

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device.")
            return
        }

        let mtkView = MTKView(frame: .zero, device: device)
        self.mtkView = mtkView
        mtkView.backgroundColor = .black
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mtkView)

        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        guard let renderer = SingleGlyphRenderer(metalKitView: mtkView) else {
            print("Unable to initialize glyph renderer.")
            return
        }

        self.renderer = renderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        renderer.updateZoom(scale: zoomScale)
        mtkView.delegate = renderer
        configureGestureRecognizers(for: mtkView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let mtkView = mtkView else { return }
        renderer?.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationBar()
    }

    private func configureGestureRecognizers(for view: MTKView) {
        let pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinchRecognizer)
    }

    private func applyZoom(scale: CGFloat) {
        let clamped = max(min(scale, maxZoomScale), minZoomScale)
        guard abs(clamped - zoomScale) > 0.0001 else { return }
        zoomScale = clamped
        renderer?.updateZoom(scale: zoomScale)
    }

    @objc
    private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed, .ended:
            var targetScale = zoomScale * recognizer.scale
            targetScale = max(min(targetScale, maxZoomScale), minZoomScale)
            applyZoom(scale: targetScale)
            recognizer.scale = 1.0
        case .cancelled, .failed:
            applyZoom(scale: zoomScale)
        default:
            break
        }
    }

    private func configureNavigationBar() {
        guard let navigationBar = navigationController?.navigationBar else { return }
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationController?.navigationBar.tintColor = .white
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .black
            appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
        } else {
            navigationBar.barTintColor = .black
            navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        }
        navigationBar.isTranslucent = false
        navigationBar.barStyle = .black
    }
}

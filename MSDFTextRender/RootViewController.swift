import MetalKit
import UIKit

class RootViewController: UIViewController {
    var renderer: Renderer!
    var mtkView: MTKView!
    private var modeControl: UISegmentedControl?

    private var zoomScale: CGFloat = 1.0
    private let minZoomScale: CGFloat = 0.5
    private let maxZoomScale: CGFloat = 3.0

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "Render Text in Metal"
        configureNavigationBar()
        configureModeSegmentControl()

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported")
            return
        }
        mtkView = MTKView(frame: .zero, device: defaultDevice)
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        mtkView.backgroundColor = UIColor.black
        view.addSubview(mtkView)

        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        guard let newRenderer = Renderer(metalKitView: mtkView) else {
            print("Renderer cannot be initialized")
            return
        }

        renderer = newRenderer

        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)

        mtkView.delegate = renderer
        mtkView.isMultipleTouchEnabled = true

        configureGestureRecognizers(for: mtkView)
        applyViewport(scale: zoomScale)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let mtkView else { return }
        renderer?.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationBar()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        renderer?.rebuildTextMeshForCurrentView()
    }

    private func configureGestureRecognizers(for view: MTKView) {
        let pinchRecognizer = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinch(_:)),
        )
        view.addGestureRecognizer(pinchRecognizer)
    }

    private func applyViewport(scale: CGFloat) {
        guard let renderer else { return }
        let clampedScale = max(min(scale, maxZoomScale), minZoomScale)
        zoomScale = clampedScale
        renderer.updateZoom(zoomScale: zoomScale)
        renderer.rebuildTextMeshForCurrentView()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed, .ended:
            var targetScale = zoomScale * recognizer.scale
            targetScale = max(min(targetScale, maxZoomScale), minZoomScale)
            applyViewport(scale: targetScale)
            recognizer.scale = 1.0
        case .cancelled, .failed:
            applyViewport(scale: zoomScale)
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

    private func configureModeSegmentControl() {
        let items = ["Normal", "Hollow"]
        let control = UISegmentedControl(items: items)
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(handleModeChanged(_:)), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        // Improve contrast on dark background
        if #available(iOS 13.0, *) {
            control.selectedSegmentTintColor = .white
            control.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
            control.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
            control.layer.cornerRadius = 8
            control.layer.masksToBounds = true
        } else {
            control.tintColor = .white
        }
        // Use as titleView for compact placement
        navigationItem.titleView = control
        modeControl = control
    }

    @objc
    private func handleModeChanged(_ sender: UISegmentedControl) {
        let isHollow = sender.selectedSegmentIndex == 1
        renderer?.setRenderMode(isHollow: isHollow)
    }
}

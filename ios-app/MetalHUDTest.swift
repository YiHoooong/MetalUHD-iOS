import SwiftUI
import UIKit
import MetalKit
import Darwin
import QuartzCore
import simd

// MARK: - In-process HUD switch

/// Turns the Metal Performance HUD on **for this process**. `MTL_HUD_ENABLED`
/// is what Apple's HUD library checks when the first Metal device is created;
/// the defaults keys are the documented fallback.
///
/// This is the guaranteed way to see the HUD: our own app is a development-
/// signed build, which is exactly the case Apple documents as supported.
enum MetalHUDDiagnostics {
    static func enableInProcess() {
        for key in HUDEngine.hudKeys {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.synchronize()
        setenv("MTL_HUD_ENABLED", "1", 1)
    }

    static func disableInProcess() {
        setenv("MTL_HUD_ENABLED", "0", 1)
        for key in HUDEngine.hudKeys {
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.synchronize()
    }
}

// MARK: - SwiftUI wrapper

/// A full-screen Metal view used to prove the HUD works on this device.
struct MetalHUDTestView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HUDTestViewController {
        MetalHUDDiagnostics.enableInProcess()
        return HUDTestViewController()
    }

    func updateUIViewController(_ uiViewController: HUDTestViewController, context: Context) {}
}

// MARK: - View controller

final class HUDTestViewController: UIViewController {
    private var mtkView: MTKView?
    private var renderer: HUDTestRenderer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            showMessage("This device has no Metal device.")
            return
        }

        let metalView = MTKView(frame: view.bounds, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1)
        metalView.preferredFramesPerSecond = 60
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        view.addSubview(metalView)
        mtkView = metalView

        guard let renderer = HUDTestRenderer(device: device, view: metalView) else {
            showMessage("Could not build the Metal pipeline.")
            return
        }
        self.renderer = renderer
        metalView.delegate = renderer

        MetalHUDDiagnostics.enableInProcess()

        let hint = UILabel()
        hint.text = "If the Metal HUD works, an overlay appears in the top-right corner: FPS, frame time, GPU time."
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 12)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        MetalHUDDiagnostics.disableInProcess()
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}

// MARK: - Renderer

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float4 color;
};

vertex VOut v_main(uint vid [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
    float2 p[3] = { float2(0.0, 0.75), float2(-0.72, -0.62), float2(0.72, -0.62) };
    float3 c[3] = { float3(1.0, 0.32, 0.18), float3(0.25, 1.0, 0.45), float3(0.30, 0.55, 1.0) };
    VOut o;
    o.position = mvp * float4(p[vid], 0.0, 1.0);
    o.color = float4(c[vid], 1.0);
    return o;
}

fragment float4 f_main(VOut in [[stage_in]]) {
    return in.color;
}
"""

final class HUDTestRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let startTime = CACurrentMediaTime()

    init?(device: MTLDevice, view: MTKView) {
        guard let queue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            return nil
        }
        guard let vertexFunction = library.makeFunction(name: "v_main"),
              let fragmentFunction = library.makeFunction(name: "f_main") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let elapsed = Float(CACurrentMediaTime() - startTime)
        let angle = elapsed * 0.9
        let c = cosf(angle)
        let s = sinf(angle)

        let mvp = simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))

        encoder.setRenderPipelineState(pipeline)
        withUnsafePointer(to: mvp) { pointer in
            encoder.setVertexBytes(pointer, length: MemoryLayout<simd_float4x4>.size, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

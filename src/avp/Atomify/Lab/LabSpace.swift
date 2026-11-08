import AtomifyVision
import CompositorServices
import Foundation

/// The immersive lab, drawn with Metal through a compositor layer: a render
/// thread draws whatever `LabScene` last published, and on the main actor
/// the driver runs the simulation's frame loop and the pinches move atoms
/// and the experiment.
@MainActor
enum LabSpace {
    static func start(_ layer: LabLayer, model: AppModel) {
        let scene = LabScene()
        let driver = LabDriver()
        let interaction = LabInteraction()
        let input = LabInput(model: model, scene: scene, driver: driver, interaction: interaction)
        layer.renderer.onSpatialEvent = { events in input.receive(events) }

        model.openLabs += 1
        let presentationID = UUID()
        model.activeLabPresentation = presentationID

        // Restart the driver whenever a different simulation is loaded.
        let updates = Task { @MainActor in
            while !Task.isCancelled {
                let id = model.run?.id
                let current = Task { @MainActor in
                    await driver.run(model: model, scene: scene, interaction: interaction)
                }
                while !Task.isCancelled && model.run?.id == id {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                current.cancel()
                await current.value
                input.end()
            }
        }

        let loop = LabRenderLoop(layer: layer.renderer, mailbox: scene.mailbox)
        let thread = Thread {
            loop.run()
            // One exit path for Back to Experiences, the Digital Crown and
            // system dismissal: stop the run, reopen the experiences, close
            // the panel.
            Task { @MainActor in
                updates.cancel()
                input.end()
                model.openLabs = max(0, model.openLabs - 1)
                // A late end of an earlier presentation must not stop the
                // run that replaced it.
                guard model.activeLabPresentation == presentationID else { return }
                model.activeLabPresentation = nil
                model.stop()
                model.restoreLibrary?()
            }
        }
        thread.name = "Atomify lab renderer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

import AppKit
import AtomifyRender
import SwiftUI

/// Frame rate, timings and counts, updated four times a second.
struct StatsOverlay: View {
    let model: LabModel

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 2) {
            row("fps", stats.fps.map { Format.fixed($0, digits: 0) } ?? "–")
            row("frame", Format.milliseconds(stats.frameMs))
            row("cpu", Format.milliseconds(stats.cpuMs))
            row("gpu", Format.milliseconds(stats.gpuMs))
            if model.isAnimating {
                row("jitter", Format.milliseconds(stats.jitterMs))
                row("upload", Format.milliseconds(stats.uploadMs))
            } else {
                row("upload", Format.milliseconds(stats.lastUploadMs))
            }
            row("particles", stats.particlesDrawn.formatted())
            row("bonds", stats.bondsDrawn.formatted())
            if let generated = model.generated {
                row("scene", "\(generated.particleCount.formatted()) p, \(generated.bondCount.formatted()) b")
            }
            if let generation = model.generationMs {
                row("generate", Format.milliseconds(generation))
            }
            if model.host == .particleView {
                Text("ParticleView reports GPU time and counts only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
        }
    }
}

/// A colormap as a horizontal gradient.
struct ColormapStrip: View {
    let colormap: Colormap

    var body: some View {
        LinearGradient(colors: colormap.table(count: 17).map(Format.color),
                       startPoint: .leading, endPoint: .trailing)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Color bar for per-particle colors: the quantity, the gradient, and its range.
struct ColorBarLegend: View {
    let info: ColorLegendInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title)
                .font(.caption)
            ColormapStrip(colormap: info.colormap)
                .frame(width: 200, height: 12)
            HStack {
                Text(Format.fixed(info.range.lowerBound, digits: 2))
                Spacer()
                Text(Format.fixed((info.range.lowerBound + info.range.upperBound) / 2, digits: 2))
                Spacer()
                Text(Format.fixed(info.range.upperBound, digits: 2))
            }
            .font(.caption2.monospaced())
            .frame(width: 200)
            Text(info.colormap.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}

/// Progress of a running benchmark, or its result.
struct BenchmarkPanel: View {
    let model: LabModel

    var body: some View {
        switch model.benchmark {
        case .idle:
            EmptyView()
        case .running(let seconds):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Benchmarking: one orbit in \(Int(seconds)) s")
                Button("Cancel") { model.cancelBenchmark() }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                Button("Dismiss") { model.dismissBenchmarkResult() }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .finished(let result):
            BenchmarkResultView(result: result,
                                onCopy: { copyToPasteboard(result.report) },
                                onDismiss: { model.dismissBenchmarkResult() })
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct BenchmarkResultView: View {
    let result: BenchmarkResult
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Benchmark")
                .font(.headline)
            Text(result.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("mean")
                    Text("p95")
                }
                .foregroundStyle(.secondary)
                GridRow {
                    Text("frame").gridColumnAlignment(.leading)
                    Text(Format.milliseconds(result.meanFrameMs))
                    Text(Format.milliseconds(result.p95FrameMs))
                }
                GridRow {
                    Text("cpu")
                    Text(Format.milliseconds(result.meanCPUMs))
                    Text(Format.milliseconds(result.p95CPUMs))
                }
                GridRow {
                    Text("gpu")
                    Text(Format.milliseconds(result.meanGPUMs))
                    Text(Format.milliseconds(result.p95GPUMs))
                }
                if result.meanUploadMs != nil {
                    GridRow {
                        Text("upload")
                        Text(Format.milliseconds(result.meanUploadMs))
                        Text("")
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            Text("\(result.frames) frames in \(Format.fixed(result.seconds, digits: 1)) s · \(Format.fixed(result.fps, digits: 1)) fps · max \(Format.milliseconds(result.maxFrameMs))")
                .font(.caption.monospaced())
            Text("\(result.particlesDrawn.formatted()) particles, \(result.bondsDrawn.formatted()) bonds drawn")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy", action: onCopy)
                Button("Dismiss", action: onDismiss)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

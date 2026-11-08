import AtomifyKit
import Charts
import SwiftUI

/// The selected atom, live plots and the LAMMPS console.
struct InspectorView: View {
    let session: SimulationSession

    var body: some View {
        VSplitView {
            // A List, not a ScrollView: on macOS 27 buttons inside a
            // ScrollView in the inspector column get no clicks (Deselect did
            // nothing, while the same button in a List, or with no scroll
            // view, works). The List scrolls the same and looks the same.
            List {
                VStack(alignment: .leading, spacing: 18) {
                    SelectedAtomSection(session: session)
                    Divider()
                    PlotsSection(session: session)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 200, idealHeight: 480)

            ConsoleSection(session: session)
                .frame(minHeight: 140, idealHeight: 260)
        }
    }
}

// MARK: Selected atom

struct SelectedAtomSection: View {
    let session: SimulationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected atom").font(.headline)
                Spacer()
                if session.selectedAtom != nil {
                    Button("Deselect") { session.clearSelection() }
                        .buttonStyle(.link)
                }
            }
            if let atom = session.selectedAtom {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("ID", "\(atom.tag)")
                    row("Type", atom.typeName.map { "\(atom.type) (\($0))" } ?? "\(atom.type)")
                    row("x", Format.number(Double(atom.position.x)))
                    row("y", Format.number(Double(atom.position.y)))
                    row("z", Format.number(Double(atom.position.z)))
                    if let radius = atom.radius {
                        row("Radius", Format.number(Double(radius)))
                    }
                    if let quantity = atom.quantity, let value = atom.value {
                        row(quantity, Format.number(Double(value)))
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            } else {
                Text("Click an atom to inspect it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

// MARK: Plots

struct PlotsSection: View {
    let session: SimulationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plots").font(.headline)
                Spacer()
                Menu {
                    let plotted = Set(session.plottedSeries)
                    ForEach(PlotCatalog.groups, id: \.self) { group in
                        let options = session.plotOptions.filter { $0.group == group }
                        if !options.isEmpty {
                            Section(group) {
                                ForEach(options) { option in
                                    Button(option.title) { session.addPlot(option.key) }
                                        .disabled(plotted.contains(option.key))
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add plot", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(session.plotOptions.isEmpty)
            }
            if session.plottedSeries.isEmpty {
                Text(session.plotOptions.isEmpty
                     ? "Computes, fixes and variables appear here while a simulation runs."
                     : "Add a plot from the menu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.plottedSeries, id: \.self) { key in
                PlotCard(title: session.title(of: key), points: session.plotData[key] ?? []) {
                    session.removePlot(key)
                }
            }
        }
    }
}

struct PlotCard: View {
    let title: String
    let points: [SIMD2<Double>]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let last = points.last {
                    Text(Format.number(last.y)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove plot")
            }
            Chart {
                ForEach(points.indices, id: \.self) { i in
                    LineMark(x: .value("Time", points[i].x), y: .value(title, points[i].y))
                        .interpolationMethod(.linear)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel("Time")
            .frame(height: 120)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Console

struct ConsoleSection: View {
    let session: SimulationSession
    @State private var command = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Clear") { session.clearConsole() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(session.console.lines.enumerated()), id: \.offset) { item in
                            Text(item.element.isEmpty ? " " : item.element)
                        }
                        if !session.console.pending.isEmpty {
                            Text(session.console.pending)
                        }
                        Color.clear.frame(height: 1).id(ConsoleSection.bottom)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: session.console.revision) {
                    proxy.scrollTo(ConsoleSection.bottom, anchor: .bottom)
                }
            }

            HStack {
                TextField("LAMMPS command, e.g. fix 2 all langevin 1.0 1.0 1.0 48279", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(send)
                Button("Run", action: send)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || !session.status.isActive)
            }
            .padding(8)
        }
    }

    private static let bottom = "console-bottom"

    private func send() {
        session.enqueue(command)
        command = ""
    }
}

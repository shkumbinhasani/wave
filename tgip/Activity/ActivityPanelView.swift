import SwiftUI

/// Chrome-task-manager-style breakdown for the "Wave Activity" window: what
/// Wave itself costs (rendering, mostly) vs what the processes inside each
/// tab cost. Sampling runs only while the window is open.
struct ActivityPanelView: View {
    @State private var monitor = ActivityMonitor()
    @State private var copyConfirmationUntil: Date?

    var body: some View {
        Group {
            if monitor.app == nil && monitor.tabs.isEmpty && monitor.other.isEmpty {
                ProgressView("Sampling…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let app = monitor.app {
                        Section("Wave") {
                            appRows(app)
                        }
                    }
                    if !monitor.tabs.isEmpty {
                        Section("Tabs") {
                            ForEach(monitor.tabs) { GroupRow(group: $0) }
                        }
                    }
                    if !monitor.other.isEmpty {
                        Section("Other") {
                            ForEach(monitor.other) { GroupRow(group: $0) }
                        }
                    }
                    Section {
                    } footer: {
                        Text("Sampled every \(Int(ActivityMonitor.sampleInterval)) seconds. CPU is % of one core, so a busy group can exceed 100%. High Wave CPU while a tab streams output is rendering cost — the work originates in the tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                copyButton
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// Copies the current sample as plain text — for pasting into a chat or
    /// bug report when something is eating CPU.
    private var copyButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(monitor.reportText(), forType: .string)
            let deadline = Date.now.addingTimeInterval(1.5)
            copyConfirmationUntil = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // A later click re-armed the label; let its own reset win.
                if copyConfirmationUntil == deadline { copyConfirmationUntil = nil }
            }
        } label: {
            let confirming = copyConfirmationUntil != nil
            Label(
                confirming ? "Copied" : "Copy Report",
                systemImage: confirming ? "checkmark" : "doc.on.doc"
            )
        }
        .help("Copy a plain-text snapshot of this panel to the clipboard")
    }

    @ViewBuilder
    private func appRows(_ app: ActivityMonitor.AppSample) -> some View {
        DisclosureGroup {
            ForEach(app.threads) { thread in
                MetricLine(
                    name: thread.name,
                    detail: nil,
                    cpu: thread.cpuPercent,
                    memory: nil
                )
            }
        } label: {
            MetricLine(
                name: "Wave (terminal, rendering, UI)",
                detail: nil,
                cpu: app.cpuPercent,
                memory: app.memoryBytes,
                prominent: true
            )
        }
    }
}

private struct GroupRow: View {
    let group: ActivityMonitor.Group

    var body: some View {
        DisclosureGroup {
            ForEach(group.processes) { process in
                MetricLine(
                    name: process.name,
                    detail: "pid \(process.id)",
                    cpu: process.cpuPercent,
                    memory: process.memoryBytes
                )
            }
        } label: {
            MetricLine(
                name: group.title,
                detail: group.subtitle,
                cpu: group.cpuPercent,
                memory: group.memoryBytes,
                prominent: true
            )
        }
    }
}

/// One aligned name / CPU / memory line, shared by group and process rows.
private struct MetricLine: View {
    let name: String
    let detail: String?
    let cpu: Double
    let memory: UInt64?
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(prominent ? .body.weight(.medium) : .body)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(String(format: "%.1f%%", cpu))
                .monospacedDigit()
                .foregroundStyle(cpu >= 50 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 64, alignment: .trailing)
            Text(memory.map { Int64($0).formatted(.byteCount(style: .memory)) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }
}

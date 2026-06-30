import SwiftUI

/// Drives the indicator UI. Updated on the main thread by `IndicatorController`.
final class IndicatorModel: ObservableObject {
    enum Phase: Equatable { case recording, processing }
    @Published var phase: Phase = .recording
    /// Live mic level, 0...1, used for the waveform.
    @Published var level: Float = 0
}

/// The floating pill shown near the caret: a waveform while recording, a
/// spinner while transcribing. Minimal, native styling.
struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Waveform(level: model.level)
                    .frame(width: 56, height: 20)
            case .processing:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// A small bar-graph waveform whose bars react to the live mic level with a
/// gentle continuous shimmer so it reads as "listening".
private struct Waveform: View {
    var level: Float
    private let bars = 5
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(height: barHeight(i, maxHeight: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func barHeight(_ index: Int, maxHeight: CGFloat) -> CGFloat {
        let lvl = CGFloat(max(0, min(1, level)))
        // Per-bar shimmer so it animates even at low input.
        let shimmer = 0.35 + 0.65 * abs(sin(Double(index) * 0.9 + phase * .pi))
        let h = maxHeight * (0.18 + lvl * 0.82) * CGFloat(shimmer)
        return max(3, min(maxHeight, h))
    }
}

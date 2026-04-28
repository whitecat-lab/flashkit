import SwiftUI

struct WriteCompletionOverlay: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 14) {
                HStack(spacing: 24) {
                    RetroUSBIcon()
                        .frame(width: 168, height: 76)
                        .accessibilityHidden(true)

                    Rectangle()
                        .fill(.white.opacity(0.62))
                        .frame(width: 2, height: 92)
                        .shadow(color: .white.opacity(0.45), radius: 4)

                    Text("Finished")
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.7), radius: 5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.black.opacity(0.72))
                        .overlay(ScanlineTexture().clipShape(RoundedRectangle(cornerRadius: 5)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.78), lineWidth: 2)
                        .shadow(color: .white.opacity(0.6), radius: 7)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Finished")

                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(28)
        }
    }
}

private struct RetroUSBIcon: View {
    var body: some View {
        Canvas { context, size in
            let stroke = Color.white.opacity(0.86)
            let fill = Color.white.opacity(0.08)
            let bodyRect = CGRect(x: size.width * 0.05, y: size.height * 0.18, width: size.width * 0.7, height: size.height * 0.64)
            let plugRect = CGRect(x: bodyRect.maxX, y: size.height * 0.33, width: size.width * 0.2, height: size.height * 0.34)

            context.addFilter(.shadow(color: .white.opacity(0.65), radius: 3))
            context.fill(Path(roundedRect: bodyRect, cornerRadius: 12), with: .color(fill))
            context.stroke(Path(roundedRect: bodyRect, cornerRadius: 12), with: .color(stroke), lineWidth: 4)
            context.fill(Path(plugRect), with: .color(fill))
            context.stroke(Path(plugRect), with: .color(stroke), lineWidth: 4)

            let notchSize = CGSize(width: plugRect.width * 0.22, height: plugRect.height * 0.28)
            for y in [plugRect.minY + plugRect.height * 0.2, plugRect.maxY - plugRect.height * 0.2 - notchSize.height] {
                let notch = CGRect(x: plugRect.minX + plugRect.width * 0.38, y: y, width: notchSize.width, height: notchSize.height)
                context.fill(Path(notch), with: .color(stroke.opacity(0.75)))
            }

            var branch = Path()
            branch.move(to: CGPoint(x: bodyRect.midX - 28, y: bodyRect.midY))
            branch.addLine(to: CGPoint(x: bodyRect.midX + 34, y: bodyRect.midY))
            branch.move(to: CGPoint(x: bodyRect.midX + 7, y: bodyRect.midY))
            branch.addLine(to: CGPoint(x: bodyRect.midX + 28, y: bodyRect.minY + 16))
            branch.move(to: CGPoint(x: bodyRect.midX + 7, y: bodyRect.midY))
            branch.addLine(to: CGPoint(x: bodyRect.midX + 29, y: bodyRect.maxY - 16))
            context.stroke(branch, with: .color(stroke), style: StrokeStyle(lineWidth: 5, lineCap: .square, lineJoin: .round))

            context.fill(Path(CGRect(x: bodyRect.midX - 39, y: bodyRect.midY - 5, width: 12, height: 10)), with: .color(stroke))
            context.fill(Path(ellipseIn: CGRect(x: bodyRect.midX + 24, y: bodyRect.minY + 11, width: 11, height: 11)), with: .color(stroke))
            context.fill(Path(CGRect(x: bodyRect.midX + 23, y: bodyRect.maxY - 20, width: 12, height: 12)), with: .color(stroke))
        }
    }
}

private struct ScanlineTexture: View {
    var body: some View {
        Canvas { context, size in
            for y in stride(from: CGFloat.zero, through: size.height, by: 4) {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(0.12)))
            }
        }
        .blendMode(.plusLighter)
    }
}

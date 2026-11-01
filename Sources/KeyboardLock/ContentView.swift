import SwiftUI

// Keep the macOS 13 property wrapper when newer SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

private enum Palette {
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.18)
    static let muted = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let navy = Color(red: 0.12, green: 0.21, blue: 0.35)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.98)
}

struct ContentView: View {
    @ObservedObject var service: KeyboardLockService
    @ViewState private var duration = 180
    @ViewState private var showsInfo = false

    var body: some View {
        LockScreen(
            isLocked: service.isLocked,
            hasPermission: service.hasAccessibilityPermission,
            permissionRequested: service.permissionRequested,
            remainingSeconds: service.remainingSeconds,
            duration: $duration,
            error: service.errorMessage,
            showsInfo: $showsInfo,
            primaryAction: {
                if service.isLocked {
                    service.unlock()
                } else if service.hasAccessibilityPermission {
                    service.start(duration: TimeInterval(duration))
                } else {
                    service.requestPermission()
                }
            },
            permissionSettingsAction: { service.openPermissionSettings() }
        )
        .onAppear { service.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refreshPermission()
        }
    }
}

/// Use short labels for state and actions; keep supporting details available on demand.
struct LockScreen: View {
    let isLocked: Bool
    let hasPermission: Bool
    let permissionRequested: Bool
    let remainingSeconds: Int
    @Binding var duration: Int
    let error: String?
    @Binding var showsInfo: Bool
    let primaryAction: () -> Void
    let permissionSettingsAction: () -> Void

    private enum Control: Hashable { case primary, duration(Int), info, settings }
    @FocusState private var focus: Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actionLabel: String {
        isLocked ? "结束清洁" : (hasPermission ? "锁定键盘" : (permissionRequested ? "重新检查权限" : "开启辅助功能权限"))
    }

    private var buttonTitle: String {
        isLocked ? "结束清洁" : (hasPermission ? "锁定键盘" : (permissionRequested ? "检查权限" : "开启权限"))
    }

    private var time: String {
        String(format: "%02d:%02d", max(0, remainingSeconds) / 60, max(0, remainingSeconds) % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 18)
            KeyboardIllustration(isLocked: isLocked)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isLocked ? "键盘已锁定" : "键盘未锁定")
                .help(isLocked ? "键盘已锁定" : (hasPermission ? "点击锁图标开始" : (permissionRequested ? "点击刷新图标检查权限" : "点击手掌图标授权")))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isLocked)

            Group {
                if isLocked {
                    HStack(spacing: 15) {
                        ZStack {
                            Circle().stroke(Palette.navy.opacity(0.10), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: min(1, max(0, Double(remainingSeconds) / Double(max(1, duration)))))
                                .stroke(Palette.navy, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "timer").font(.system(size: 13, weight: .medium))
                        }
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动解锁")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                            Text(time)
                                .font(.system(size: 32, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(Palette.navy)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("距离自动解锁还有 \(remainingSeconds) 秒")
                    .help("到时自动解锁")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("自动解锁", systemImage: "timer")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                        HStack(spacing: 4) {
                            durationButton(60)
                            durationButton(180)
                            durationButton(300)
                        }
                        .padding(4)
                        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("自动解锁时间")
                }
            }
            .frame(height: 64)
            .padding(.top, 20)

            Button(action: primaryAction) {
                HStack(spacing: 9) {
                    Image(systemName: isLocked ? "lock.open.fill" : (hasPermission ? "lock.fill" : (permissionRequested ? "arrow.clockwise" : "hand.raised.fill")))
                        .font(.system(size: 16, weight: .medium))
                    Text(buttonTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 280, height: 52)
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PrimaryButtonStyle())
            .focused($focus, equals: .primary)
            .overlay { focusOutline(focus == .primary, radius: 19) }
            .padding(.top, 20)
            .help(actionLabel)
            .accessibilityLabel(actionLabel)
            .accessibilityHint(isLocked ? "立即恢复键盘输入" : (hasPermission ? "鼠标和触控板保持可用" : (permissionRequested ? "仅检查授权状态，不弹出授权提示" : "在系统设置中允许键盘锁控制键盘")))

            // A real failure must remain visible, even in a graphical interface.
            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.55, green: 0.23, blue: 0.18))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)

            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 480, height: 480)
        .background(Palette.paper)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack {
            Text("键盘锁")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Label(isLocked ? "已锁定" : (hasPermission ? "未锁定" : "待授权"), systemImage: isLocked ? "lock.fill" : (hasPermission ? "lock.open" : "hand.raised"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isLocked ? Palette.navy : Palette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.navy.opacity(isLocked ? 0.09 : 0.035), in: Capsule())
        }
        .frame(height: 24)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("离线", systemImage: "network.slash")
                .help("纯本地 · 无网络")
                .accessibilityLabel("纯本地，网络连接已禁用")
            Label("鼠标可用", systemImage: "computermouse")
                .help("鼠标与触控板可用")
                .accessibilityLabel("鼠标与触控板可用")
            Spacer()
            if !hasPermission && permissionRequested {
                Button(action: permissionSettingsAction) {
                    Label("设置", systemImage: "gearshape")
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .settings)
                .overlay { focusOutline(focus == .settings, radius: 7) }
                .help("打开辅助功能设置")
                .accessibilityLabel("打开辅助功能设置")
            }
            Button { showsInfo.toggle() } label: {
                Image(systemName: "info.circle")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .info)
            .overlay { focusOutline(focus == .info, radius: 7) }
            .help("使用说明")
            .accessibilityLabel("使用说明")
            .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 18) {
                    info("lock", "电源键、Touch ID 和部分系统操作除外")
                    info("computermouse", "点击“结束清洁”，或等待倒计时")
                    info("network.slash", "不联网，不记录按键")
                }
                .padding(22)
                .frame(width: 280)
                .background(Palette.paper)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .frame(height: 28)
    }

    private func info(_ symbol: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 20, height: 19)
                .foregroundStyle(Palette.navy)
                .accessibilityHidden(true)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func durationButton(_ seconds: Int) -> some View {
        Button { duration = seconds } label: {
            Text("\(seconds / 60) 分钟")
                .font(.system(size: 14, weight: duration == seconds ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(duration == seconds ? Palette.ink : Palette.muted)
                .frame(width: 88, height: 34)
                .background(duration == seconds ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(duration == seconds ? 0.06 : 0), radius: 2, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .duration(seconds))
        .overlay { focusOutline(focus == .duration(seconds), radius: 10) }
        .help("\(seconds / 60) 分钟后自动解锁")
        .accessibilityLabel("自动解锁：\(seconds / 60) 分钟")
        .accessibilityAddTraits(duration == seconds ? .isSelected : [])
    }

    private func focusOutline(_ isFocused: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(Palette.navy.opacity(isFocused ? 0.55 : 0), lineWidth: 2)
            .padding(-3)
            .allowsHitTesting(false)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(configuration.isPressed ? Palette.ink : Palette.navy, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct KeyboardIllustration: View {
    let isLocked: Bool
    private let keyWidths: [[CGFloat]] = [
        Array(repeating: 1, count: 13),
        Array(repeating: 1, count: 13),
        [1.4] + Array(repeating: 1, count: 11) + [1.4],
        [1.6] + Array(repeating: 1, count: 10) + [1.6],
        [1.9] + Array(repeating: 1, count: 10) + [1.9],
        [1, 1, 1, 1.2, 5.2, 1.2, 1, 1, 1, 1]
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                ForEach(keyWidths.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(keyWidths[row].indices, id: \.self) { column in
                            let unit = (366 - CGFloat(keyWidths[row].count - 1) * 4) / keyWidths[row].reduce(0, +)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isLocked ? Palette.navy : Color(red: 0.17, green: 0.19, blue: 0.22))
                                .frame(width: unit * keyWidths[row][column], height: row == 0 ? 10 : 21)
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5) }
                                .shadow(color: .black.opacity(0.22), radius: 0, y: 1)
                        }
                    }
                }
            }
            .padding(12)
            .background(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.78)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Color.white.opacity(0.7), lineWidth: 1) }
            .shadow(color: Palette.ink.opacity(0.10), radius: 15, y: 10)

            if isLocked {
                RoundedRectangle(cornerRadius: 15).fill(Palette.navy.opacity(0.22))
                Image(systemName: "lock.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Palette.navy, in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.18), lineWidth: 1) }
                    .shadow(color: Palette.ink.opacity(0.2), radius: 12, y: 6)
            }
        }
        .frame(width: 390, height: 159)
    }
}

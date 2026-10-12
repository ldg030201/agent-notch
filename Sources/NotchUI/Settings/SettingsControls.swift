import SwiftUI

// 설정 화면 공통 부품.
// 스냅숏(ImageRenderer)은 AppKit 기반 컨트롤(Form · 토글 · Picker · Slider · Stepper · 기본 버튼 등)을 그리지 못하므로
// (배포 대상 macOS 14 로 빌드하면 자리표시 그림이 나온다) 순수 SwiftUI 로 만들거나, 스냅숏에서만 같은 모양의 정지 그림으로 바꾼다.

// MARK: - 색상

struct SettingsPalette {
    let windowBackground: Color
    let sidebarBackground: Color
    let groupBackground: Color
    let groupBorder: Color
    let separator: Color
    let selection: Color
    let overlayDim: Color
    let logBackground: Color
    let controlFill: Color
    let controlBorder: Color

    static let accent = Color(hex: 0x0A84FF)
    static let green = Color(hex: 0x34C759)
    static let orange = Color(hex: 0xEF9F27)
    static let red = Color(hex: 0xE5484D)

    static func resolve(_ scheme: ColorScheme) -> SettingsPalette {
        switch scheme {
        case .dark:
            return SettingsPalette(
                windowBackground: Color(hex: 0x1E1E1E),
                sidebarBackground: Color(hex: 0x252525),
                groupBackground: Color(hex: 0x2A2A2A),
                groupBorder: Color.white.opacity(0.08),
                separator: Color.white.opacity(0.08),
                selection: Color.white.opacity(0.1),
                overlayDim: Color.black.opacity(0.45),
                logBackground: Color.black.opacity(0.35),
                controlFill: Color.white.opacity(0.12),
                controlBorder: Color.white.opacity(0.1)
            )
        default:
            return SettingsPalette(
                windowBackground: Color(hex: 0xF2F2F0),
                sidebarBackground: Color(hex: 0xE8E8E5),
                groupBackground: Color.white,
                groupBorder: Color.black.opacity(0.08),
                separator: Color.black.opacity(0.07),
                selection: Color.black.opacity(0.08),
                overlayDim: Color.black.opacity(0.25),
                logBackground: Color.black.opacity(0.05),
                controlFill: Color.white,
                controlBorder: Color.black.opacity(0.14)
            )
        }
    }
}

// MARK: - 묶음 · 행

/// 둥근 상자로 묶은 설정 묶음 (제목 + 행들)
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SettingsPalette.resolve(colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(palette.groupBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.groupBorder, lineWidth: 0.5)
            )
        }
    }
}

/// 설정 한 줄: 왼쪽 제목(+ 설명), 오른쪽 조절 요소
struct SettingsRow<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// 묶음 안 행 사이 구분선
struct SettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(SettingsPalette.resolve(colorScheme).separator)
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

/// 묶음 안 안내 문구 한 줄
struct SettingsNote: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    /// 본문을 기본 글자색으로 (강조)
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(text)
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - 스위치

/// macOS 스위치 모양의 토글 (순수 SwiftUI)
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            SwitchKnob(isOn: configuration.$isOn)
        }
    }
}

private struct SwitchKnob: View {
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let off = colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? SettingsPalette.accent : off)
            // 그림자 대신 얇은 테두리 (오프스크린 렌더링 결과가 늘 같도록)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .padding(2)
        }
        .frame(width: 32, height: 18)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture {
            guard isEnabled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "켬" : "끔")
        .accessibilityAction { if isEnabled { isOn.toggle() } }
    }
}

// MARK: - 버튼

/// macOS 테두리 버튼 모양 (순수 SwiftUI)
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SettingsPalette.resolve(colorScheme)
        let fill = prominent ? (destructive ? SettingsPalette.red : SettingsPalette.accent) : palette.controlFill
        configuration.label
            .font(.system(size: 13))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : (destructive ? SettingsPalette.red : Color.primary))
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : palette.controlBorder, lineWidth: 0.5)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 고르기 · 슬라이더

/// 메뉴 Picker. 스냅숏에서는 같은 모양의 정지 그림.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    @Environment(\.islandRenderContext) private var renderContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if renderContext.isSnapshot {
            let palette = SettingsPalette.resolve(colorScheme)
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .frame(height: 22)
            .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(palette.controlBorder, lineWidth: 0.5)
            )
        } else {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// 슬라이더. 스냅숏에서는 같은 모양의 정지 그림.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var width: CGFloat = 160

    @Environment(\.islandRenderContext) private var renderContext
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if renderContext.isSnapshot {
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let knob: CGFloat = 18
            let track = colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.1)
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 4)
                Capsule().fill(SettingsPalette.accent).frame(width: knob / 2 + fraction * (width - knob), height: 4)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * (width - knob))
            }
            .frame(width: width, height: 20)
            .opacity(isEnabled ? 1 : 0.45)
        } else {
            Slider(value: $value, in: range, step: step)
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }
}

// MARK: - 숫자 조절

/// − 값 + (Stepper 대신)
struct SettingsStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 10)
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("줄이기")

            Text(format(value))
                .monospacedDigit()
                .frame(minWidth: 44)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 10)
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel("늘리기")
        }
        .buttonStyle(SettingsButtonStyle())
    }
}

// MARK: - 작은 표시

/// 작은 둥근 꼬리표 (준비 중, 지금 버전 등)
struct SettingsTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 정지 상태로도 그릴 수 있는 작은 진행 표시 (ProgressView 대신)
struct SettingsSpinner: View {
    var size: CGFloat = 12

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        Group {
            if renderContext.isSnapshot {
                Circle()
                    .inset(by: 1.2)
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                SpinnerView(color: .secondaryLabelColor, lineWidth: 1.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("진행 중")
    }
}

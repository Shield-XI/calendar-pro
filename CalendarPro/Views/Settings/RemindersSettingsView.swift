import AppKit
import EventKit
import SwiftUI

// 文件头：
// 职责：设置窗口「提醒事项」独立菜单页——承载提醒事项看板设置组
//       （开关、看板提醒列表勾选、显示已完成、完成后保留显示、分组模式、
//       颜色模式、配色预设与逐色自定义），自 EventsSettingsView 原样迁移。
// 入口：SettingsRootView.detailView（侧栏 .reminders 项）。
// 输入来源：SettingsStore.menuBarPreferences 看板字段、
//       EventService.reminderCalendars 与提醒事项授权状态。
// 输出：看板设置界面；写入经 SettingsStore setter 持久化。
// 依赖：SwiftUI、AppKit（NSColor 转换）、EventKit（EKCalendar）、
//       RemindersBoardModels、BoardColorPreferences。
// 副作用：无直接副作用；设置变更经 SettingsStore 落盘。

struct RemindersSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var eventService: EventService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("提醒看板")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("显示提醒事项看板"), isOn: showRemindersBoardBinding)
                            .toggleStyle(.checkbox)

                        if store.menuBarPreferences.showRemindersBoard {
                            Divider()

                            if !eventService.remindersAuthorized {
                                permissionRow(
                                    title: L("Reminders Access Required"),
                                    buttonTitle: L("Request Access")
                                ) {
                                    Task {
                                        await eventService.requestReminderAccess()
                                    }
                                }
                            } else {
                                boardListsSection

                                Divider()

                                boardDisplaySection

                                Divider()

                                boardColorSection
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
        }
    }

    private var showRemindersBoardBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.showRemindersBoard },
            set: { store.setShowRemindersBoard($0) }
        )
    }

    private var boardShowCompletedBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.boardShowCompleted },
            set: { store.setBoardShowCompleted($0) }
        )
    }

    private var boardCompletedRetentionSecondsBinding: Binding<Int> {
        Binding(
            get: { store.menuBarPreferences.boardCompletedRetentionSeconds },
            set: { store.setBoardCompletedRetentionSeconds($0) }
        )
    }

    private var boardGroupingModeBinding: Binding<RemindersBoardGroupingMode> {
        Binding(
            get: { store.menuBarPreferences.boardGroupingMode },
            set: { store.setBoardGroupingMode($0) }
        )
    }

    private var boardColorModeBinding: Binding<RemindersBoardColorMode> {
        Binding(
            get: { store.menuBarPreferences.boardColorMode },
            set: { store.setBoardColorMode($0) }
        )
    }

    private var boardColorPresetBinding: Binding<BoardColorPreset> {
        Binding(
            get: { store.menuBarPreferences.boardColorPreset },
            set: { store.setBoardColorPreset($0) }
        )
    }

    private func boardReminderCalendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: {
                let enabledIDs = store.menuBarPreferences.boardEnabledReminderCalendarIDs
                return enabledIDs.isEmpty || enabledIDs.contains(calendarID)
            },
            set: {
                store.setBoardReminderCalendarEnabled(
                    $0,
                    calendarID: calendarID,
                    allCalendarIDs: eventService.reminderCalendars.map(\.calendarIdentifier)
                )
            }
        )
    }

    private func boardColorBinding(for key: BoardColorKey) -> Binding<Color> {
        Binding(
            get: {
                let preferences = store.menuBarPreferences.boardColorPreferences
                return Color(boardColorHex: preferences.colorHex(for: key))
            },
            set: { color in
                store.setBoardColorHex(Self.hexString(from: color), for: key)
            }
        )
    }

    /// Color → "#RRGGBB"（统一转 sRGB），解析失败回退中性灰。
    private static func hexString(from color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return "#8E8E93"
        }

        let red = Int(round(srgb.redComponent * 255))
        let green = Int(round(srgb.greenComponent * 255))
        let blue = Int(round(srgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// 看板启用的提醒列表勾选区（空=全选归一语义与日程提醒列表一致）。
    private var boardListsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("看板提醒列表"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if eventService.reminderCalendars.isEmpty {
                Text(L("No Reminder Lists Available"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(
                        eventService.reminderCalendars,
                        id: \.calendarIdentifier
                    ) { calendar in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: calendar.color))
                                .frame(width: 10, height: 10)
                            Text(calendar.title)
                                .font(.system(size: 12))
                            Spacer()
                            Toggle(
                                "",
                                isOn: boardReminderCalendarEnabledBinding(
                                    for: calendar.calendarIdentifier
                                )
                            )
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    /// 看板展示选项：显示已完成、完成后保留显示、分组模式、颜色模式。
    private var boardDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("显示已完成"), isOn: boardShowCompletedBinding)
                .toggleStyle(.checkbox)

            HStack {
                Text(L("完成后保留显示"))
                    .font(.system(size: 12))
                Spacer()
                Picker(L("完成后保留显示"), selection: boardCompletedRetentionSecondsBinding) {
                    Text(L("立即隐藏")).tag(0)
                    Text(L("1 秒")).tag(1)
                    Text(L("3 秒")).tag(3)
                    Text(L("5 秒")).tag(5)
                    Text(L("10 秒")).tag(10)
                }
                .frame(width: 160)
                .labelsHidden()
            }

            HStack {
                Text(L("分组模式"))
                    .font(.system(size: 12))
                Spacer()
                Picker(L("分组模式"), selection: boardGroupingModeBinding) {
                    ForEach(RemindersBoardGroupingMode.allCases) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                .frame(width: 160)
                .labelsHidden()
            }

            HStack {
                Text(L("颜色模式"))
                    .font(.system(size: 12))
                Spacer()
                Picker(L("颜色模式"), selection: boardColorModeBinding) {
                    ForEach(RemindersBoardColorMode.allCases) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                .frame(width: 160)
                .labelsHidden()
            }
        }
    }

    /// 看板配色：预设 Picker + 全部颜色 ColorPicker 网格（逐色改动即转 custom）。
    private var boardColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("配色方案"))
                    .font(.system(size: 12))
                Spacer()
                Picker(L("配色方案"), selection: boardColorPresetBinding) {
                    ForEach(BoardColorPreset.allCases) { preset in
                        Text(preset.displayTitle).tag(preset)
                    }
                }
                .frame(width: 160)
                .labelsHidden()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(boardColorKeyRows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(boardColorKeyRows[rowIndex]) { key in
                            boardColorPickerCell(key: key)
                        }
                    }
                }
            }
        }
    }

    private let boardColorKeys = BoardColorKey.allCases

    /// 颜色键按每行两个切分；键总数为奇数时末行单格渲染，不越界。
    private var boardColorKeyRows: [[BoardColorKey]] {
        stride(from: 0, to: boardColorKeys.count, by: 2).map { start in
            Array(boardColorKeys[start..<min(start + 2, boardColorKeys.count)])
        }
    }

    private func boardColorPickerCell(key: BoardColorKey) -> some View {
        HStack(spacing: 6) {
            ColorPicker(
                key.displayTitle,
                selection: boardColorBinding(for: key),
                supportsOpacity: false
            )
            .labelsHidden()
            .fixedSize()

            Text(key.displayTitle)
                .font(.system(size: 12))
        }
    }

    private func permissionRow(
        title: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

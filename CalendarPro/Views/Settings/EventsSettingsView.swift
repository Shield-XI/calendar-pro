import AppKit
import SwiftUI
import EventKit

struct EventsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var eventService: EventService

    struct CalendarGroup {
        let source: EKSource?
        let calendars: [EKCalendar]
    }

    private var calendarGroups: [CalendarGroup] {
        let calendars = eventService.calendars
        let grouped = Dictionary(grouping: calendars, by: { $0.source })
        let groups = grouped.map { CalendarGroup(source: $0.key, calendars: $0.value) }
        return groups.sorted { lhs, rhs in
            let lhsTitle = lhs.source?.title ?? ""
            let rhsTitle = rhs.source?.title ?? ""
            return lhsTitle < rhsTitle
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("Events")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("Show Events in Panel"), isOn: showEventsBinding)
                            .toggleStyle(.checkbox)

                        Text(L("Show Events Description"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if store.menuBarPreferences.showEvents {
                            Divider()

                            upcomingIndicatorSection

                            Divider()

                            Text(L("Data Sources"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            calendarEventsSection

                            Divider()

                            remindersSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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

    private var showEventsBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.showEvents },
            set: { store.setShowEvents($0) }
        )
    }

    private var showCalendarEventsBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.showCalendarEvents },
            set: { store.setShowCalendarEvents($0) }
        )
    }

    private func calendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: {
                let enabledIDs = store.menuBarPreferences.enabledCalendarIDs
                return enabledIDs.isEmpty || enabledIDs.contains(calendarID)
            },
            set: {
                store.setCalendarEnabled(
                    $0,
                    calendarID: calendarID,
                    allCalendarIDs: eventService.calendars.map(\.calendarIdentifier)
                )
            }
        )
    }

    private var showRemindersBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.showReminders },
            set: { store.setShowReminders($0) }
        )
    }

    private var showUpcomingIndicatorBinding: Binding<Bool> {
        Binding(
            get: { store.menuBarPreferences.showUpcomingIndicator },
            set: { store.setShowUpcomingIndicator($0) }
        )
    }

    private var upcomingReminderMinutesBinding: Binding<Int> {
        Binding(
            get: { store.menuBarPreferences.upcomingReminderMinutes },
            set: { store.setUpcomingReminderMinutes($0) }
        )
    }

    private func reminderCalendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: {
                let enabledIDs = store.menuBarPreferences.enabledReminderCalendarIDs
                return enabledIDs.isEmpty || enabledIDs.contains(calendarID)
            },
            set: {
                store.setReminderCalendarEnabled(
                    $0,
                    calendarID: calendarID,
                    allCalendarIDs: eventService.reminderCalendars.map(\.calendarIdentifier)
                )
            }
        )
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
                Color(boardColorHex: store.menuBarPreferences.boardColorPreferences.colorHex(for: key))
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

    private var upcomingIndicatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Show Upcoming Indicator"), isOn: showUpcomingIndicatorBinding)
                .toggleStyle(.checkbox)

            Text(L("Show Upcoming Indicator Description"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.menuBarPreferences.showUpcomingIndicator {
                HStack {
                    Text(L("Remind Before"))
                    Spacer()
                    Picker(L("Remind Before"), selection: upcomingReminderMinutesBinding) {
                        Text("5 \(L("minutes"))").tag(5)
                        Text("10 \(L("minutes"))").tag(10)
                        Text("15 \(L("minutes"))").tag(15)
                        Text("30 \(L("minutes"))").tag(30)
                        Text("60 \(L("minutes"))").tag(60)
                    }
                    .frame(width: 120)
                    .labelsHidden()
                }
            }
        }
    }

    private var calendarEventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Include Calendar Events"), isOn: showCalendarEventsBinding)
                .toggleStyle(.checkbox)

            if !eventService.isAuthorized {
                permissionRow(
                    title: L("Calendar Access Required"),
                    buttonTitle: L("Request Access")
                ) {
                    Task {
                        await eventService.requestAccess()
                    }
                }
            } else if store.menuBarPreferences.showCalendarEvents {
                Text(L("Choose Calendars"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if eventService.calendars.isEmpty {
                    Text(L("No Calendars Available"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(calendarGroups, id: \.source?.title) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.source?.title ?? L("Unknown"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)

                                VStack(spacing: 4) {
                                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                                        HStack {
                                            Circle()
                                                .fill(Color(nsColor: calendar.color))
                                                .frame(width: 10, height: 10)
                                            Text(calendar.title)
                                                .font(.system(size: 12))
                                            Spacer()
                                            Toggle("", isOn: calendarEnabledBinding(for: calendar.calendarIdentifier))
                                                .toggleStyle(.checkbox)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Include Reminders"), isOn: showRemindersBinding)
                .toggleStyle(.checkbox)

            if !eventService.remindersAuthorized {
                permissionRow(
                    title: L("Reminders Access Required"),
                    buttonTitle: L("Request Access")
                ) {
                    Task {
                        await eventService.requestReminderAccess()
                    }
                }
            } else if store.menuBarPreferences.showReminders {
                Text(L("Choose Reminder Lists"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if eventService.reminderCalendars.isEmpty {
                    Text(L("No Reminder Lists Available"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(eventService.reminderCalendars, id: \.calendarIdentifier) { calendar in
                            HStack {
                                Circle()
                                    .fill(Color(nsColor: calendar.color))
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                                    .font(.system(size: 12))
                                Spacer()
                                Toggle("", isOn: reminderCalendarEnabledBinding(for: calendar.calendarIdentifier))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
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
                    ForEach(eventService.reminderCalendars, id: \.calendarIdentifier) { calendar in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: calendar.color))
                                .frame(width: 10, height: 10)
                            Text(calendar.title)
                                .font(.system(size: 12))
                            Spacer()
                            Toggle(
                                "",
                                isOn: boardReminderCalendarEnabledBinding(for: calendar.calendarIdentifier)
                            )
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    /// 看板展示选项：显示已完成、分组模式、颜色模式。
    private var boardDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("显示已完成"), isOn: boardShowCompletedBinding)
                .toggleStyle(.checkbox)

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

    private func permissionRow(title: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
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

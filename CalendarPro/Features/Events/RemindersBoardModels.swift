import AppKit
import EventKit
import Foundation
import SwiftUI

// 文件头：
// 职责：提醒事项看板的纯函数展示模型——分组模式与颜色模式枚举、
//       EKReminder.priority 到优先级档的映射、到期时间桶解析、
//       BoardSnapshot 分组/排序/着色布局，以及 hex 颜色互转辅助。
// 入口：BoardSnapshot.make(reminders:now:calendar:groupingMode:colorMode:colorPreferences:showCompleted:)。
// 输入来源：EventService.fetchBoardReminders 返回的 EKReminder 与 MenuBarPreferences 看板字段。
// 输出：BoardSnapshot（分组 + 行展示态 + 未完成总数），供 RemindersBoardSection 渲染与单元测试断言。
// 依赖：EventKit（仅读取 EKReminder/EKCalendar 属性）、AppKit/SwiftUI（NSColor/Color 十六进制转换）。
// 副作用：无（纯函数，不做任何存储或网络操作）。

/// 看板分组模式：按提醒列表或按优先级档。
enum RemindersBoardGroupingMode: String, Codable, CaseIterable, Identifiable {
    case list
    case priority

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .list: return L("按列表")
        case .priority: return L("按优先级")
        }
    }
}

/// 看板颜色模式：逾期/未逾期双色，或按到期时间分段着色。
enum RemindersBoardColorMode: String, Codable, CaseIterable, Identifiable {
    case overdue
    case timeBucket

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .overdue: return L("逾期着色")
        case .timeBucket: return L("时间分段着色")
        }
    }
}

/// 提醒事项优先级档：映射 EKReminder.priority（0 无；1-3 高；4-6 中；7-9 低）。
/// rawValue 即分组展示顺序（高在前，无优先级靠后）。
enum ReminderBoardPriority: Int, Codable, CaseIterable, Identifiable {
    case high = 0
    case medium = 1
    case low = 2
    case none = 3

    var id: Int { rawValue }

    /// 纯函数映射，便于单元测试覆盖各优先级区间。
    init(ekPriority: Int) {
        switch ekPriority {
        case 1...3: self = .high
        case 4...6: self = .medium
        case 7...9: self = .low
        default: self = .none
        }
    }

    var displayTitle: String {
        switch self {
        case .high: return L("高")
        case .medium: return L("中")
        case .low: return L("低")
        case .none: return L("无")
        }
    }
}

extension EKReminder {
    /// 当前提醒的优先级档（看板展示用）。
    var boardPriority: ReminderBoardPriority {
        ReminderBoardPriority(ekPriority: priority)
    }
}

/// 到期时间桶：过去（今天零点前）、今天、本周（今天起 7 天内）、更晚、无日期。
enum ReminderBoardTimeBucket: Equatable {
    case past
    case today
    case thisWeek
    case later
    case none

    /// 纯函数解析：以 now 所在自然日零点为界比较 dueDate 所在自然日。
    /// - Parameters:
    ///   - dueDate: 到期日期；nil 表示无日期，返回 .none
    ///   - now: 参考当前时间（来源：TimeRefreshCoordinator.currentDate）
    ///   - calendar: 用于自然日与零点计算的日历（测试注入 GMT 固定日历）
    static func resolve(
        dueDate: Date?,
        now: Date,
        calendar: Calendar
    ) -> ReminderBoardTimeBucket {
        guard let dueDate else { return .none }

        let dayStart = calendar.startOfDay(for: now)
        let dueStart = calendar.startOfDay(for: dueDate)

        if dueStart < dayStart {
            return .past
        }
        if dueStart == dayStart {
            return .today
        }

        // 本周窗口：今天零点起 7 天内（不含第 8 天零点及以后）。
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: dayStart) else {
            return .later
        }
        return dueStart < weekEnd ? .thisWeek : .later
    }
}

/// 看板单行展示态：由 EKReminder 派生的纯值，颜色已按偏好解析为 hex。
struct RemindersBoardRow: Identifiable, Equatable {
    let id: String
    let title: String
    let listName: String
    let listColorHex: String
    let isCompleted: Bool
    let dueDate: Date?
    let dueText: String?
    let priority: ReminderBoardPriority
    let bucket: ReminderBoardTimeBucket
    let colorHex: String
}

/// 看板分组：标题与组头颜色由分组模式决定（列表名+列表色，或优先级档+优先级色）。
struct BoardSnapshotGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let colorHex: String
    let rows: [RemindersBoardRow]
}

/// 看板布局快照：分组结果与未完成总数。
struct BoardSnapshot: Equatable {
    let groups: [BoardSnapshotGroup]
    let incompleteCount: Int

    /// 纯函数构建看板快照。
    /// - Parameters:
    ///   - reminders: 待展示的提醒事项（来源：EventService.fetchBoardReminders）
    ///   - now: 参考当前时间，用于时间桶解析
    ///   - calendar: 自然日计算所用日历（默认当前日历，测试可注入 GMT 日历）
    ///   - groupingMode: 分组模式（按列表/按优先级）
    ///   - colorMode: 颜色模式（逾期双色/时间分段）
    ///   - colorPreferences: 看板颜色偏好（hex 值集）
    ///   - showCompleted: 是否包含已完成提醒；false 时直接过滤
    /// - Returns: 排序、着色完成后的快照；异常数据（无日历/无标题）给默认兜底文案
    static func make(
        reminders: [EKReminder],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        groupingMode: RemindersBoardGroupingMode,
        colorMode: RemindersBoardColorMode,
        colorPreferences: BoardColorPreferences,
        showCompleted: Bool
    ) -> BoardSnapshot {
        let visibleReminders = reminders.filter { showCompleted || !$0.isCompleted }

        let rows = visibleReminders
            .map { makeRow(for: $0, now: now, calendar: calendar, colorMode: colorMode, colorPreferences: colorPreferences) }
            .sorted(by: makeRowComparator(calendar: calendar))

        let groups: [BoardSnapshotGroup]
        switch groupingMode {
        case .list:
            groups = listGroups(from: rows)
        case .priority:
            groups = priorityGroups(from: rows, colorPreferences: colorPreferences)
        }

        let incompleteCount = rows.filter { !$0.isCompleted }.count
        return BoardSnapshot(groups: groups, incompleteCount: incompleteCount)
    }

    // MARK: - 行构建

    private static func makeRow(
        for reminder: EKReminder,
        now: Date,
        calendar: Calendar,
        colorMode: RemindersBoardColorMode,
        colorPreferences: BoardColorPreferences
    ) -> RemindersBoardRow {
        let dueDate = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
        let hasExplicitTime = reminder.dueDateComponents.map { components in
            components.hour != nil || components.minute != nil || components.second != nil
        } ?? false
        let bucket = ReminderBoardTimeBucket.resolve(dueDate: dueDate, now: now, calendar: calendar)
        let identifier = reminder.calendarItemIdentifier
        let fallbackIdentifier = "unsaved-\(reminder.title ?? "")-\(dueDate?.timeIntervalSinceReferenceDate ?? 0)"

        return RemindersBoardRow(
            id: identifier.isEmpty ? fallbackIdentifier : identifier,
            title: reminder.title?.isEmpty == false ? reminder.title! : L("无标题"),
            listName: reminder.calendar?.title.isEmpty == false ? reminder.calendar!.title : L("未知列表"),
            listColorHex: hexString(from: reminder.calendar?.color),
            isCompleted: reminder.isCompleted,
            dueDate: dueDate,
            dueText: dueDate.map { dueText(for: $0, includesTime: hasExplicitTime) },
            priority: reminder.boardPriority,
            bucket: bucket,
            colorHex: resolveColorHex(
                isCompleted: reminder.isCompleted,
                bucket: bucket,
                colorMode: colorMode,
                colorPreferences: colorPreferences
            )
        )
    }

    /// 着色规则：已完成恒用 completed 色；无日期恒用 noDate 色；
    /// 其余按颜色模式取逾期双色或时间分段色。
    private static func resolveColorHex(
        isCompleted: Bool,
        bucket: ReminderBoardTimeBucket,
        colorMode: RemindersBoardColorMode,
        colorPreferences: BoardColorPreferences
    ) -> String {
        if isCompleted {
            return colorPreferences.completed
        }
        guard bucket != .none else {
            return colorPreferences.noDate
        }

        switch colorMode {
        case .overdue:
            return bucket == .past ? colorPreferences.overdue : colorPreferences.notOverdue
        case .timeBucket:
            switch bucket {
            case .past: return colorPreferences.past
            case .today: return colorPreferences.today
            case .thisWeek: return colorPreferences.thisWeek
            case .later: return colorPreferences.later
            case .none: return colorPreferences.noDate
            }
        }
    }

    // MARK: - 排序与分组

    /// 组内排序：有到期时间者按时间升序在前，无日期者靠后，同档按标题。
    private static func makeRowComparator(calendar: Calendar)
    -> (RemindersBoardRow, RemindersBoardRow) -> Bool {
        { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// 按提醒列表名分组，组按名称排序；组头用列表色。
    private static func listGroups(from rows: [RemindersBoardRow]) -> [BoardSnapshotGroup] {
        let grouped = Dictionary(grouping: rows, by: \.listName)
        return grouped
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { listName, groupRows in
                BoardSnapshotGroup(
                    id: "list-\(listName)",
                    title: listName,
                    colorHex: groupRows.first?.listColorHex ?? "#8E8E93",
                    rows: groupRows
                )
            }
    }

    /// 按优先级档分组（高/中/低/无顺序），跳过空组；组头用对应优先级色。
    private static func priorityGroups(
        from rows: [RemindersBoardRow],
        colorPreferences: BoardColorPreferences
    ) -> [BoardSnapshotGroup] {
        ReminderBoardPriority.allCases.compactMap { priority in
            let groupRows = rows.filter { $0.priority == priority }
            guard !groupRows.isEmpty else { return nil }

            let headerColorHex: String
            switch priority {
            case .high: headerColorHex = colorPreferences.priorityHigh
            case .medium: headerColorHex = colorPreferences.priorityMedium
            case .low: headerColorHex = colorPreferences.priorityLow
            case .none: headerColorHex = colorPreferences.priorityNone
            }

            return BoardSnapshotGroup(
                id: "priority-\(priority.rawValue)",
                title: priority.displayTitle,
                colorHex: headerColorHex,
                rows: groupRows
            )
        }
    }

    // MARK: - 展示辅助

    /// 到期格式器缓存（键=是否含时刻+语言标识）；DateFormatter 创建开销大，按需缓存。
    /// UI 主线程与测试均会调用，用锁保护；语言切换后键变化会新建，不依赖失效逻辑。
    private nonisolated(unsafe) static var dueTextFormatters: [String: DateFormatter] = [:]
    private static let dueTextFormattersLock = NSLock()

    /// 到期文案：带时刻用 "M月d日 HH:mm" 模板，纯日期用 "M月d日" 模板（随本地化）。
    private static func dueText(for date: Date, includesTime: Bool) -> String {
        let locale = AppLocalization.locale
        let key = "\(includesTime)-\(locale.identifier)"

        dueTextFormattersLock.lock()
        defer { dueTextFormattersLock.unlock() }

        if let cached = dueTextFormatters[key] {
            return cached.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(includesTime ? "MdHm" : "Md")
        dueTextFormatters[key] = formatter
        return formatter.string(from: date)
    }

    /// NSColor 转 "#RRGGBB" hex（统一转 sRGB）；无法解析时回退中性灰。
    static func hexString(from color: NSColor?) -> String {
        guard let srgb = color?.usingColorSpace(.sRGB) else {
            return "#8E8E93"
        }

        let red = Int(round(srgb.redComponent * 255))
        let green = Int(round(srgb.greenComponent * 255))
        let blue = Int(round(srgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension Color {
    /// 从 "#RRGGBB" 十六进制字符串创建颜色；解析失败回退系统次要标签色。
    init(boardColorHex hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let integer = UInt64(value, radix: 16) else {
            self.init(nsColor: .secondaryLabelColor)
            return
        }

        self.init(
            red: Double((integer >> 16) & 0xFF) / 255,
            green: Double((integer >> 8) & 0xFF) / 255,
            blue: Double(integer & 0xFF) / 255
        )
    }
}

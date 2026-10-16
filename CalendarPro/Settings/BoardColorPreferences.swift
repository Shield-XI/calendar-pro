import Foundation

// 文件头：
// 职责：定义提醒事项看板的颜色偏好模型（hex 存储）、颜色键与预设方案。
// 入口：MenuBarPreferences.boardColorPreferences / boardColorPreset 引用。
// 输入来源：用户在设置页的配色方案选择与逐色修改。
// 输出：Codable 结构随 MenuBarPreferences 持久化到 UserDefaults。
// 依赖：Foundation（纯值类型，不依赖 UI）。
// 副作用：无。

/// 提醒事项看板颜色偏好：全部颜色以 "#RRGGBB" hex 字符串存储，
/// 便于 Codable 持久化与纯函数测试；颜色解析失败时由 UI 层回退灰色。
struct BoardColorPreferences: Codable, Equatable, Hashable {
    var overdue: String
    var notOverdue: String
    var past: String
    var today: String
    var thisWeek: String
    var later: String
    var noDate: String
    var priorityHigh: String
    var priorityMedium: String
    var priorityLow: String
    var priorityNone: String
    var completed: String

    /// 经典配色（默认值）：逾期红、今天橙、本周蓝、无日期灰、高红中橙低蓝。
    static let classic = BoardColorPreferences(
        overdue: "#DC2626",
        notOverdue: "#2563EB",
        past: "#DC2626",
        today: "#EA580C",
        thisWeek: "#2563EB",
        later: "#64748B",
        noDate: "#9CA3AF",
        priorityHigh: "#DC2626",
        priorityMedium: "#EA580C",
        priorityLow: "#2563EB",
        priorityNone: "#9CA3AF",
        completed: "#9CA3AF"
    )

    /// 读取指定颜色键的 hex 值。
    func colorHex(for key: BoardColorKey) -> String {
        switch key {
        case .overdue: return overdue
        case .notOverdue: return notOverdue
        case .past: return past
        case .today: return today
        case .thisWeek: return thisWeek
        case .later: return later
        case .noDate: return noDate
        case .priorityHigh: return priorityHigh
        case .priorityMedium: return priorityMedium
        case .priorityLow: return priorityLow
        case .priorityNone: return priorityNone
        case .completed: return completed
        }
    }

    /// 写入指定颜色键的 hex 值（preset 转 custom 由 SettingsStore 统一处理）。
    mutating func setColorHex(_ hex: String, for key: BoardColorKey) {
        switch key {
        case .overdue: overdue = hex
        case .notOverdue: notOverdue = hex
        case .past: past = hex
        case .today: today = hex
        case .thisWeek: thisWeek = hex
        case .later: later = hex
        case .noDate: noDate = hex
        case .priorityHigh: priorityHigh = hex
        case .priorityMedium: priorityMedium = hex
        case .priorityLow: priorityLow = hex
        case .priorityNone: priorityNone = hex
        case .completed: completed = hex
        }
    }
}

/// 看板颜色键：设置页逐色修改时定位具体颜色；改动任意一键即转为 custom 预设。
enum BoardColorKey: String, CaseIterable, Identifiable {
    case overdue
    case notOverdue
    case past
    case today
    case thisWeek
    case later
    case noDate
    case priorityHigh
    case priorityMedium
    case priorityLow
    case priorityNone
    case completed

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .overdue: return L("逾期")
        case .notOverdue: return L("未逾期")
        case .past: return L("过去")
        case .today: return L("今天")
        case .thisWeek: return L("本周")
        case .later: return L("更晚")
        case .noDate: return L("无日期")
        case .priorityHigh: return L("高优先级")
        case .priorityMedium: return L("中优先级")
        case .priorityLow: return L("低优先级")
        case .priorityNone: return L("无优先级")
        case .completed: return L("已完成")
        }
    }
}

/// 看板配色预设：选中即整套套用颜色；用户改动任意一色后自动转 custom。
/// 各套语义保持一致：逾期红系、今天橙系、本周蓝系、无日期灰系、
/// 优先级高红/中橙/低蓝/无灰、已完成灰。
enum BoardColorPreset: String, Codable, CaseIterable, Identifiable {
    case classic
    case warm
    case cool
    case highContrast
    case custom

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .classic: return L("经典")
        case .warm: return L("暖色")
        case .cool: return L("冷色")
        case .highContrast: return L("高对比度")
        case .custom: return L("自定义")
        }
    }

    /// 预设对应的完整颜色方案；custom 无预设值，保留用户已改的颜色。
    var colorPreferences: BoardColorPreferences? {
        switch self {
        case .classic:
            return .classic
        case .warm:
            return BoardColorPreferences(
                overdue: "#B91C1C",
                notOverdue: "#D97706",
                past: "#B91C1C",
                today: "#EA580C",
                thisWeek: "#CA8A04",
                later: "#78716C",
                noDate: "#A8A29E",
                priorityHigh: "#B91C1C",
                priorityMedium: "#EA580C",
                priorityLow: "#CA8A04",
                priorityNone: "#A8A29E",
                completed: "#A8A29E"
            )
        case .cool:
            return BoardColorPreferences(
                overdue: "#DB2777",
                notOverdue: "#0284C7",
                past: "#DB2777",
                today: "#0891B2",
                thisWeek: "#2563EB",
                later: "#7C3AED",
                noDate: "#94A3B8",
                priorityHigh: "#DB2777",
                priorityMedium: "#0891B2",
                priorityLow: "#2563EB",
                priorityNone: "#94A3B8",
                completed: "#94A3B8"
            )
        case .highContrast:
            return BoardColorPreferences(
                overdue: "#D70015",
                notOverdue: "#0040DD",
                past: "#D70015",
                today: "#C93400",
                thisWeek: "#0040DD",
                later: "#5E5CE6",
                noDate: "#8E8E93",
                priorityHigh: "#D70015",
                priorityMedium: "#C93400",
                priorityLow: "#0040DD",
                priorityNone: "#8E8E93",
                completed: "#8E8E93"
            )
        case .custom:
            return nil
        }
    }
}

import SwiftUI
import EventKit

// 文件头：
// 职责：日历弹层中的「提醒事项看板」可折叠分节——标题栏（未完成总数）、
//       分组头与任务行（完成勾选 + 优先级标识 + 标题 + 到期标签）。
// 入口：CalendarPopoverView.calendarView 在日程分节之后插入本分节。
// 输入来源：RootPopoverView 注入的看板提醒数组与 MenuBarPreferences 看板字段。
// 输出：无直接输出；勾选交互通过 onToggleReminder 回调交由 EventService 落库。
// 依赖：BoardSnapshot（纯函数布局）、TimeRefreshCoordinator（当前时间）、EventKit。
// 副作用：无（仅渲染与回调转发）。

/// 提醒事项看板分节：默认收起，展开后内部 ScrollView 限高约 200。
struct RemindersBoardSection: View {
    private enum Metrics {
        static let expandedMaxHeight: CGFloat = 200
        static let chevronWidth: CGFloat = 12
        static let priorityDotSize: CGFloat = 6
        static let rowLeadingIndent: CGFloat = 18
    }

    let reminders: [EKReminder]
    let groupingMode: RemindersBoardGroupingMode
    let colorMode: RemindersBoardColorMode
    let colorPreferences: BoardColorPreferences
    let showCompleted: Bool
    @ObservedObject var timeRefreshCoordinator: TimeRefreshCoordinator
    let onToggleReminder: (EKReminder) -> Void

    @State private var isExpanded = false

    private var snapshot: BoardSnapshot {
        BoardSnapshot.make(
            reminders: reminders,
            now: timeRefreshCoordinator.currentDate,
            calendar: .autoupdatingCurrent,
            groupingMode: groupingMode,
            colorMode: colorMode,
            colorPreferences: colorPreferences,
            showCompleted: showCompleted
        )
    }

    /// 勾选交互需要按行 id 反查 EKReminder（行本身是纯值）。
    private var remindersByID: [String: EKReminder] {
        Dictionary(
            reminders.map { ($0.calendarItemIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                boardContent
            }
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        let snapshot = snapshot

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.chevronWidth)

                Text(L("提醒事项看板"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 12)

                if snapshot.incompleteCount > 0 {
                    Text("\(snapshot.incompleteCount)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-popover-reminders-board-header")
    }

    // MARK: - 展开内容

    @ViewBuilder
    private var boardContent: some View {
        let snapshot = snapshot

        if snapshot.groups.isEmpty {
            Text(L("暂无提醒事项"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.groups) { group in
                        boardGroup(group)
                    }
                }
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.expandedMaxHeight)
        }
    }

    private func boardGroup(_ group: BoardSnapshotGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(boardColorHex: group.colorHex))
                    .frame(width: 7, height: 7)

                Text(group.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            let remindersByID = remindersByID
            ForEach(group.rows) { row in
                boardRow(row, reminder: remindersByID[row.id])
            }
        }
    }

    // MARK: - 任务行

    private func boardRow(_ row: RemindersBoardRow, reminder: EKReminder?) -> some View {
        HStack(spacing: 6) {
            Button {
                if let reminder {
                    onToggleReminder(reminder)
                }
            } label: {
                Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(row.isCompleted ? Color(boardColorHex: row.colorHex) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(reminder == nil)
            .help(L("已完成"))

            Circle()
                .fill(Color(boardColorHex: priorityDotColorHex(for: row)))
                .frame(width: Metrics.priorityDotSize, height: Metrics.priorityDotSize)
                .help(row.priority.displayTitle)

            Text(row.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(row.isCompleted)
                .foregroundStyle(row.isCompleted ? Color.secondary : Color.primary)

            Spacer(minLength: 8)

            if let dueText = row.dueText {
                Text(dueText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(boardColorHex: row.colorHex))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, Metrics.rowLeadingIndent)
        .contentShape(Rectangle())
    }

    /// 优先级圆点颜色：已完成行随 completed 色，其余按优先级档取偏好色。
    private func priorityDotColorHex(for row: RemindersBoardRow) -> String {
        if row.isCompleted {
            return colorPreferences.completed
        }

        switch row.priority {
        case .high: return colorPreferences.priorityHigh
        case .medium: return colorPreferences.priorityMedium
        case .low: return colorPreferences.priorityLow
        case .none: return colorPreferences.priorityNone
        }
    }
}

import SwiftUI
import EventKit

// 文件头：
// 职责：弹层“未来日程”可折叠分节。UpcomingSnapshot 负责把统一的 CalendarItem
//       列表按天分组（纯函数，便于测试）；UpcomingEventsSection 负责折叠标题、
//       天头与条目渲染及“加载更多”入口。
// 输入：EventService.fetchUpcomingCalendarItems 取回的未来窗口内 [CalendarItem]、
//       当前时间（TimeRefreshCoordinator）与分组用日历。
// 输出：按天升序分组的快照结构 / 弹层内的分节视图。
// 依赖：EventKit（EKEvent/EKReminder）、SwiftUI、AppLocalization（L/LF）。

struct UpcomingDayGroup: Identifiable {
    let id: String
    let dayStart: Date
    let headerText: String
    let items: [CalendarItem]
}

struct UpcomingSnapshot {
    let dayGroups: [UpcomingDayGroup]
    let totalItemCount: Int

    /// 把未来条目按天分组并升序排列。
    /// - Parameters:
    ///   - items: 窗口内的统一条目（事件或带到期时间的提醒），无开始日期的条目会被忽略
    ///   - now: 当前时间，用于生成“今天/明天”天头
    ///   - calendar: 分组用的日历（测试注入固定时区）
    /// - Returns: 天组按 startOfDay 升序；同一天内全天条目在前，其余按开始时间升序
    static func make(
        items: [CalendarItem],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> UpcomingSnapshot {
        let placedEntries = items.compactMap { item -> (date: Date, item: CalendarItem)? in
            guard let startDate = item.startDate else { return nil }
            return (startDate, item)
        }

        let sortedEntries = placedEntries.sorted { lhs, rhs in
            let lhsDay = calendar.startOfDay(for: lhs.date)
            let rhsDay = calendar.startOfDay(for: rhs.date)
            if lhsDay != rhsDay {
                return lhsDay < rhsDay
            }
            if lhs.item.isAllDay != rhs.item.isAllDay {
                return lhs.item.isAllDay
            }
            return lhs.date < rhs.date
        }

        var grouped: [(dayStart: Date, items: [CalendarItem])] = []
        for entry in sortedEntries {
            let dayStart = calendar.startOfDay(for: entry.date)
            if let lastIndex = grouped.indices.last,
               calendar.isDate(grouped[lastIndex].dayStart, inSameDayAs: dayStart) {
                grouped[lastIndex].items.append(entry.item)
            } else {
                grouped.append((dayStart, [entry.item]))
            }
        }

        let dayGroups = grouped.map { group in
            UpcomingDayGroup(
                id: String(group.dayStart.timeIntervalSinceReferenceDate),
                dayStart: group.dayStart,
                headerText: dayHeaderText(for: group.dayStart, now: now, calendar: calendar),
                items: group.items
            )
        }

        return UpcomingSnapshot(
            dayGroups: dayGroups,
            totalItemCount: dayGroups.reduce(0) { $0 + $1.items.count }
        )
    }

    /// 天头文案：今天 / 明天，其余按本地化“M月d日”模板格式化。
    private static func dayHeaderText(
        for dayStart: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(dayStart, inSameDayAs: now) {
            return L("Upcoming Today")
        }

        if let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(dayStart, inSameDayAs: tomorrow) {
            return L("Upcoming Tomorrow")
        }

        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "Md",
            options: 0,
            locale: AppLocalization.locale
        )
        return formatter.string(from: dayStart)
    }
}

struct UpcomingEventsSection: View {
    private enum Metrics {
        static let expandedMaxHeight: CGFloat = 200
    }

    let items: [CalendarItem]
    let isLoading: Bool
    let windowDays: Int
    let dayLimit: Int
    let timeRefreshCoordinator: TimeRefreshCoordinator
    let selectedEventIdentifier: String?
    let onLoadMore: () -> Void
    let onSelectEvent: (EKEvent) -> Void
    let onOpenReminder: (EKReminder) -> Void
    let onToggleReminder: (EKReminder) -> Void

    // 折叠状态只记在视图内：弹层每次打开都回到默认收起，成本最低
    @State private var isExpanded = false

    var body: some View {
        // 快照只在 body 内单次求值，标题计数与展开内容共用同一份分组结果，
        // 避免 SwiftUI 对计算属性的多次访问触发重复排序与分组
        let snapshot = UpcomingSnapshot.make(
            items: items,
            now: timeRefreshCoordinator.currentDate,
            calendar: .autoupdatingCurrent
        )

        return VStack(alignment: .leading, spacing: 8) {
            headerButton(countText: countText(for: snapshot))

            if isExpanded {
                expandedContent(snapshot)
                    .frame(maxHeight: Metrics.expandedMaxHeight)
            }
        }
    }

    /// 折叠标题按钮。
    /// - Parameter countText: 右侧计数文案，来自 body 内单次求值的快照
    private func headerButton(countText: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Text(L("Upcoming Events"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(countText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-popover-upcoming-toggle")
    }

    /// 标题右侧计数文案：加载中显示 Loading，否则显示条目总数。
    /// - Parameter snapshot: body 内单次求值的分组快照
    private func countText(for snapshot: UpcomingSnapshot) -> String {
        if isLoading {
            return L("Loading")
        }
        return LF("%d items", snapshot.totalItemCount)
    }

    private var hasMore: Bool {
        // dayLimit 为 0 表示不限制窗口大小，始终可以继续加载
        dayLimit == 0 || windowDays < dayLimit
    }

    /// 展开态内容：空态文案或按天分组的滚动列表（含“加载更多”入口）。
    /// - Parameter snapshot: body 内单次求值的分组快照
    @ViewBuilder
    private func expandedContent(_ snapshot: UpcomingSnapshot) -> some View {
        if items.isEmpty, !isLoading {
            Text(L("No Upcoming Events"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.dayGroups) { group in
                        dayGroupView(group)
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    } else if hasMore {
                        loadMoreButton
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var loadMoreButton: some View {
        Button(action: onLoadMore) {
            Text(L("Load More"))
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("calendar-popover-upcoming-load-more")
    }

    private func dayGroupView(_ group: UpcomingDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.headerText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.items) { item in
                    itemButton(item)
                }
            }
        }
    }

    @ViewBuilder
    private func itemButton(_ item: CalendarItem) -> some View {
        switch item {
        case .event(let event):
            Button {
                onSelectEvent(event)
            } label: {
                EventCardView(
                    item: item,
                    isSelected: selectedEventIdentifier == event.selectionIdentifier
                )
            }
            .buttonStyle(.plain)
        case .reminder(let reminder):
            Button {
                onOpenReminder(reminder)
            } label: {
                EventCardView(
                    item: item,
                    isSelected: selectedEventIdentifier == item.selectionIdentifier,
                    onToggleReminder: onToggleReminder
                )
            }
            .buttonStyle(.plain)
        }
    }
}

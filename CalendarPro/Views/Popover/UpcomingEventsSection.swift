import SwiftUI
import EventKit

// 文件头：
// 职责：弹层“近期日程”可折叠分节。UpcomingSnapshot 负责把统一的 CalendarItem
//       列表按天分组（纯函数，便于测试）；UpcomingEventsSection 负责折叠标题、
//       天头与条目渲染及双向窗口两端滚动到边自动加载。
// 输入：EventService.fetchUpcomingCalendarItems 取回的近期窗口内 [CalendarItem]、
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

    /// 天头文案：今天 / 昨天 / 明天，其余按本地化“M月d日”模板格式化。
    private static func dayHeaderText(
        for dayStart: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(dayStart, inSameDayAs: now) {
            return L("Recent Today")
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(dayStart, inSameDayAs: yesterday) {
            return L("Recent Yesterday")
        }

        if let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(dayStart, inSameDayAs: tomorrow) {
            return L("Recent Tomorrow")
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
    let isLoadingPast: Bool
    let isLoadingFuture: Bool
    let windowDays: Int
    let dayLimit: Int
    let hasMorePast: Bool
    let defaultExpanded: Bool
    let timeRefreshCoordinator: TimeRefreshCoordinator
    let selectedEventIdentifier: String?
    let onLoadMorePast: () -> Void
    let onLoadMoreFuture: () -> Void
    let onSelectEvent: (EKEvent) -> Void
    let onOpenReminder: (EKReminder) -> Void
    let onToggleReminder: (EKReminder) -> Void

    // 折叠状态只记在视图内：初始展开态读「默认展开版块」设置；弹层重开
    // 时视图实例存活（PopoverController 复用内容视图控制器），State 的
    // 初始值只在首次创建时生效，因此在 body 的 onAppear（内容视图重新
    // 挂载即触发）按设置重置展开态——弹层每次打开取设置初值，打开期间
    // 手动折叠不会触发 onAppear，即时生效且不被复位，不持久化
    @State private var isExpanded: Bool

    /// 显式初始化器：入参由 CalendarPopoverView 透传（数据与回调来自
    /// RootPopoverView 与用户设置），defaultExpanded 来自「默认展开版块」
    /// 设置，作为折叠态的初始值。
    /// 副作用：以 defaultExpanded 初始化 @State isExpanded；展开态最终
    /// 以 body onAppear 按该值重置的结果为准（见上方状态注释）。
    init(
        items: [CalendarItem],
        isLoadingPast: Bool,
        isLoadingFuture: Bool,
        windowDays: Int,
        dayLimit: Int,
        hasMorePast: Bool,
        defaultExpanded: Bool,
        timeRefreshCoordinator: TimeRefreshCoordinator,
        selectedEventIdentifier: String?,
        onLoadMorePast: @escaping () -> Void,
        onLoadMoreFuture: @escaping () -> Void,
        onSelectEvent: @escaping (EKEvent) -> Void,
        onOpenReminder: @escaping (EKReminder) -> Void,
        onToggleReminder: @escaping (EKReminder) -> Void
    ) {
        self.items = items
        self.isLoadingPast = isLoadingPast
        self.isLoadingFuture = isLoadingFuture
        self.windowDays = windowDays
        self.dayLimit = dayLimit
        self.hasMorePast = hasMorePast
        self.defaultExpanded = defaultExpanded
        self.timeRefreshCoordinator = timeRefreshCoordinator
        self.selectedEventIdentifier = selectedEventIdentifier
        self.onLoadMorePast = onLoadMorePast
        self.onLoadMoreFuture = onLoadMoreFuture
        self.onSelectEvent = onSelectEvent
        self.onOpenReminder = onOpenReminder
        self.onToggleReminder = onToggleReminder
        _isExpanded = State(initialValue: defaultExpanded)
    }

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
        // 弹层每次打开内容视图重新挂载会再次触发 onAppear，此处按当前
        // 设置重置展开态；State(initialValue:) 仅视图首次创建时生效，
        // 无法覆盖「重开弹层取新设置值」的场景
        .onAppear {
            isExpanded = defaultExpanded
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

                Text(L("Recent Events"))
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

    /// 标题右侧计数文案：任一端加载中显示 Loading，否则显示条目总数。
    /// - Parameter snapshot: body 内单次求值的分组快照
    private func countText(for snapshot: UpcomingSnapshot) -> String {
        if isLoadingPast || isLoadingFuture {
            return L("Loading")
        }
        return LF("%d items", snapshot.totalItemCount)
    }

    /// 未来端是否还能继续扩窗：dayLimit 为 0 表示不限制窗口大小。
    private var hasMoreFuture: Bool {
        dayLimit == 0 || windowDays < dayLimit
    }

    /// 展开态内容：空态文案或按天分组的滚动列表（双向窗口，滚动到端点
    /// 自动向过去/未来扩窗）。
    /// - Parameter snapshot: body 内单次求值的分组快照
    @ViewBuilder
    private func expandedContent(_ snapshot: UpcomingSnapshot) -> some View {
        if items.isEmpty, !(isLoadingPast || isLoadingFuture) {
            Text(L("No Recent Events"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            ScrollView(.vertical) {
                // 用 LazyVStack 而非 VStack：普通 VStack 会一次性物化全部子
                // 视图，端点哨兵的 onAppear 在展开瞬间就会立即触发；LazyVStack
                // 只在子视图滚动到可视区域附近才渲染，哨兵出现即代表“已到端”
                LazyVStack(alignment: .leading, spacing: 10) {
                    if isLoadingPast {
                        progressRow
                    } else if hasMorePast {
                        loadPastTrigger
                    }

                    ForEach(snapshot.dayGroups) { group in
                        dayGroupView(group)
                    }

                    if isLoadingFuture {
                        progressRow
                    } else if hasMoreFuture {
                        loadFutureTrigger
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// 端点加载中的进度行：与哨兵互斥渲染，加载期间哨兵不在视图层级内，
    /// 不会重复触发。
    private var progressRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// 滚动到顶的加载哨兵：渲染出现即触发向过去扩窗回调。
    /// 列表首元素在展开时通常可见，属预期行为——打开即自动向过去补一个
    /// 窗口（30 天），内容不足一屏时连续加载；到达历史起点后 hasMorePast
    /// 为 false，哨兵离开视图层级不再触发。
    private var loadPastTrigger: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                guard !isLoadingPast, hasMorePast else { return }
                onLoadMorePast()
            }
    }

    /// 滚动到底的加载哨兵：渲染出现即触发向未来扩窗回调。
    /// 加载中上方分支换成进度指示、窗口达上限时 hasMoreFuture 为 false，
    /// 两种情况哨兵都不在视图层级内，不会重复触发；一次加载结束后哨兵
    /// 重新插入并再次触发 onAppear，内容不足一屏时也能连续加载直到占满
    /// 视口或达上限。
    private var loadFutureTrigger: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                guard !isLoadingFuture, hasMoreFuture else { return }
                onLoadMoreFuture()
            }
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

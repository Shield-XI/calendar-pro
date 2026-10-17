import SwiftUI
import EventKit

// Collapsible "All Events" popover section. UpcomingSnapshot groups the
// unified CalendarItem list by day (pure function, unit-testable);
// UpcomingEventsSection renders the collapsible header, day headers and
// items, and wires count-based paging (bottom sentinel auto-loads the next
// future page, the top entry row loads past pages, pagination resets and
// scroll-to-top are driven by the reset generation).
// Inputs: [CalendarItem] assembled per page by RootPopoverView, current
// time (TimeRefreshCoordinator), paging-exhaustion and reset-generation flags.
// Outputs: day-ascending snapshot struct / the section view inside the popover.
// Depends on: EventKit (EKEvent/EKReminder), SwiftUI, AppLocalization (L/LF).

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
            return L("All Today")
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(dayStart, inSameDayAs: yesterday) {
            return L("All Yesterday")
        }

        if let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(dayStart, inSameDayAs: tomorrow) {
            return L("All Tomorrow")
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
        // Scroll-to-top anchor id (view-internal only)
        static let topAnchorID = "upcomingEventsTopAnchor"
    }

    let items: [CalendarItem]
    let isLoadingPast: Bool
    let isLoadingFuture: Bool
    let hasMorePast: Bool
    let hasMoreFuture: Bool
    let defaultExpanded: Bool
    // 分页重置代数：RootPopoverView 每次重置分页递增，本节据此把滚动
    // 位置显式拉回列表顶（数据重置后滚动偏移会残留）
    let resetGeneration: Int
    let timeRefreshCoordinator: TimeRefreshCoordinator
    let selectedEventIdentifier: String?
    let onResetPagination: () -> Void
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
        hasMorePast: Bool,
        hasMoreFuture: Bool,
        defaultExpanded: Bool,
        resetGeneration: Int,
        timeRefreshCoordinator: TimeRefreshCoordinator,
        selectedEventIdentifier: String?,
        onResetPagination: @escaping () -> Void,
        onLoadMorePast: @escaping () -> Void,
        onLoadMoreFuture: @escaping () -> Void,
        onSelectEvent: @escaping (EKEvent) -> Void,
        onOpenReminder: @escaping (EKReminder) -> Void,
        onToggleReminder: @escaping (EKReminder) -> Void
    ) {
        self.items = items
        self.isLoadingPast = isLoadingPast
        self.isLoadingFuture = isLoadingFuture
        self.hasMorePast = hasMorePast
        self.hasMoreFuture = hasMoreFuture
        self.defaultExpanded = defaultExpanded
        self.resetGeneration = resetGeneration
        self.timeRefreshCoordinator = timeRefreshCoordinator
        self.selectedEventIdentifier = selectedEventIdentifier
        self.onResetPagination = onResetPagination
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
        // 弹层每次打开内容视图重新挂载会再次触发 onAppear：按当前设置
        // 重置展开态并重置分页（先重置分页状态再触发第一页装载，均由
        // onResetPagination 回调在 RootPopoverView 内一次完成），滚动
        // 位置由 resetGeneration 变化后的显式 scrollTo 拉回列表顶
        .onAppear {
            isExpanded = defaultExpanded
            onResetPagination()
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

                Text(L("All Events"))
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

    /// 标题右侧计数文案：任一端加载中显示 Loading，否则显示已加载条目数
    /// （条数分页模型下为当前已装载各页的总数）。
    /// - Parameter snapshot: body 内单次求值的分组快照
    private func countText(for snapshot: UpcomingSnapshot) -> String {
        if isLoadingPast || isLoadingFuture {
            return L("Loading")
        }
        return LF("%d items", snapshot.totalItemCount)
    }

    /// Expanded content: day-grouped scrolling list with count-based paging
    /// (bottom sentinel auto-loads the next future page; past pages load via
    /// the explicit top entry row). The empty-state text stays inside the
    /// ScrollView so the past-direction entry row remains reachable when the
    /// future window is empty.
    @ViewBuilder
    private func expandedContent(_ snapshot: UpcomingSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // LazyVStack over VStack: a plain VStack materializes every
                // child at once, so the bottom sentinel's onAppear would fire
                // the moment the section expands; lazy rendering keeps it a
                // real "scrolled near the bottom" signal
                LazyVStack(alignment: .leading, spacing: 10) {
                    topRow

                    if items.isEmpty, !(isLoadingPast || isLoadingFuture) {
                        emptyStateRow
                    } else {
                        ForEach(snapshot.dayGroups) { group in
                            dayGroupView(group)
                        }
                    }

                    if isLoadingFuture {
                        progressRow
                    } else if hasMoreFuture {
                        loadFutureTrigger
                    }
                }
                .padding(.vertical, 1)
            }
            .onChange(of: resetGeneration) { _, _ in
                // Data resets leave the stale scroll offset behind; scroll
                // back to the top anchor explicitly
                proxy.scrollTo(Metrics.topAnchorID, anchor: .top)
            }
        }
    }

    /// 空态文案行：无已加载条目且两端都不在加载时显示。留在 ScrollView
    /// 内渲染（见 expandedContent），下拉加载过去的入口不因空态丢失。
    private var emptyStateRow: some View {
        Text(L("No Events"))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    /// List top: the scroll-to-top anchor plus the past-direction row
    /// (progress while loading, otherwise the explicit load-earlier entry
    /// row; rendered only while past pages remain).
    /// macOS ScrollView has no rubber-band overscroll, so the previous
    /// pull-down probe never fired on real hardware — past-direction loading
    /// goes through this clickable row instead of a gesture.
    @ViewBuilder
    private var topRow: some View {
        // scrollTo target for reset-driven scroll-to-top
        Color.clear
            .frame(height: 0)
            .id(Metrics.topAnchorID)

        if isLoadingPast {
            progressRow
        } else if hasMorePast {
            loadEarlierRow
        }
    }

    /// Explicit entry row for loading one past page; replaced by the
    /// progress row while loading and dropped once the past end is
    /// exhausted. Plain Button keeps mouse, trackpad and full-keyboard-access
    /// activation on the same control.
    private var loadEarlierRow: some View {
        Button {
            onLoadMorePast()
        } label: {
            HStack(spacing: 4) {
                Spacer()

                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(L("Load Earlier Events"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-popover-upcoming-load-earlier")
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

    /// 滚动到底的加载哨兵：渲染出现即触发加载下一页（未来方向）。
    /// 加载中上方分支换成进度指示、探明未来尽头（hasMoreFuture 为 false，
    /// 含达设置上限与循环保护）时哨兵都不在视图层级内，不会重复触发；
    /// 一次加载结束后哨兵重新插入并再次触发 onAppear，内容不足一屏时
    /// 也能连续加载直到占满视口或探明尽头。
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

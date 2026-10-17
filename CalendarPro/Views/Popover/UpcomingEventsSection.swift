import SwiftUI
import EventKit

// 文件头：
// 职责：弹层“近期日程”可折叠分节。UpcomingSnapshot 负责把统一的 CalendarItem
//       列表按天分组（纯函数，便于测试）；UpcomingEventsSection 负责折叠标题、
//       天头与条目渲染、条数分页交互（底部哨兵自动加载下一页、顶部下拉过拉
//       向过去加载一页、弹层打开重置分页并回滚滚动位置）。
// 输入：RootPopoverView 按页装配的 [CalendarItem]、当前时间
//       （TimeRefreshCoordinator）、分页尽头与重置代数标记。
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
        // 下拉过拉触发阈值：顶部锚偏移超过该值才触发向过去加载一页
        static let pastPullTriggerOffset: CGFloat = 40
        // 滚动坐标空间与回顶锚标识（仅视图内使用）
        static let scrollCoordinateSpace = "upcomingEventsScrollSpace"
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
    // 下拉触发臂位：过拉触发后解除武装，需回弹到阈值内才重新武装，
    // 避免按住不放或加载结束后仍停在阈值上方时连续触发
    @State private var isPastPullArmed: Bool = true

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
            isPastPullArmed = true
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

    /// 标题右侧计数文案：任一端加载中显示 Loading，否则显示已加载条目数
    /// （条数分页模型下为当前已装载各页的总数）。
    /// - Parameter snapshot: body 内单次求值的分组快照
    private func countText(for snapshot: UpcomingSnapshot) -> String {
        if isLoadingPast || isLoadingFuture {
            return L("Loading")
        }
        return LF("%d items", snapshot.totalItemCount)
    }

    /// 展开态内容：空态文案或按天分组的滚动列表（条数分页：底部哨兵自动
    /// 加载下一页，顶部下拉过拉向过去加载一页，打开时重置并回顶）。
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
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // 用 LazyVStack 而非 VStack：普通 VStack 会一次性物化全部子
                    // 视图，底部哨兵的 onAppear 在展开瞬间就会立即触发；LazyVStack
                    // 只在子视图滚动到可视区域附近才渲染，哨兵出现即代表“差不多
                    // 到底”
                    LazyVStack(alignment: .leading, spacing: 10) {
                        topRow

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
                .coordinateSpace(name: Metrics.scrollCoordinateSpace)
                .onPreferenceChange(PastPullOffsetKey.self) { offset in
                    handlePastPullOffset(offset)
                }
                .onChange(of: resetGeneration) { _, _ in
                    // 数据重置后滚动偏移会残留，显式回滚到列表顶锚点
                    proxy.scrollTo(Metrics.topAnchorID, anchor: .top)
                }
            }
        }
    }

    /// 列表顶部行：常驻回顶锚（兼下拉偏移探针）+ 过去端状态行（加载中
    /// 显示进度，否则尚有更早条目时显示下拉提示；过去端不再自动加载）。
    @ViewBuilder
    private var topRow: some View {
        // 顶部锚：scrollTo 的回顶目标；GeometryReader 读取其在滚动坐标
        // 空间的 minY 供下拉过拉判定（onScrollGeometryChange 需 macOS 15+，
        // 工程部署目标 14.0，故用偏移探针）
        GeometryReader { geometry in
            Color.clear.preference(
                key: PastPullOffsetKey.self,
                value: geometry.frame(in: .named(Metrics.scrollCoordinateSpace)).minY
            )
        }
        .frame(height: 0)
        .id(Metrics.topAnchorID)

        if isLoadingPast {
            progressRow
        } else if hasMorePast {
            pastPullHintRow
        }
    }

    /// 下拉提示行：过去方向还有未加载条目时显示；触发加载后被进度行替换
    /// （isLoadingPast 分支互斥）。
    private var pastPullHintRow: some View {
        Text(L("Pull Down to Load Earlier Events"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }

    /// 下拉过拉检测：顶部锚偏移超过阈值且已武装时触发向过去加载一页；
    /// 触发后解除武装，回弹到阈值内才重新武装（与下拉刷新一致的「过拉
    /// 触发、回弹再拉」语义）；加载中或过去端已探明尽头不触发。
    /// - Parameter offset: 顶部锚在滚动坐标空间的 minY，静止时约为内容
    ///   顶部内边距，下拉过拉时增大
    private func handlePastPullOffset(_ offset: CGFloat) {
        if offset < Metrics.pastPullTriggerOffset {
            isPastPullArmed = true
            return
        }
        guard isPastPullArmed, !isLoadingPast, hasMorePast else { return }
        isPastPullArmed = false
        onLoadMorePast()
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

/// 下拉偏移透传 PreferenceKey：把顶部锚在滚动坐标空间中的 minY 传给
/// onPreferenceChange 做过拉判定；单一数据源，reduce 直接取后值。
private struct PastPullOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

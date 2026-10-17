import Combine
import SwiftUI
import EventKit
import AppKit

struct RootPopoverView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var eventService: EventService
    @ObservedObject var viewModel: CalendarPopoverViewModel
    @ObservedObject var timeRefreshCoordinator: TimeRefreshCoordinator
    @ObservedObject var pomodoroTimer: PomodoroTimerController
    @ObservedObject var pomodoroStatsStore: PomodoroStatsStore
    let onPresentEventDetailWindow: (
        EKEvent,
        @escaping (EKEvent) -> Void,
        @escaping (EKEvent) -> Void,
        @escaping () -> Void
    ) -> Void
    let onPresentReminderDetailWindow: (
        EKReminder,
        @escaping (EKReminder) -> Void,
        @escaping (EKReminder) -> Void,
        @escaping (EKReminder) -> Void,
        @escaping () -> Void
    ) -> Void
    let onPresentItemComposer: (
        CalendarItemCreationKind,
        Date,
        CalendarItemCreationTimeRange?,
        [EKCalendar],
        [EKCalendar],
        @escaping (CalendarEventCreationRequest) throws -> Void,
        @escaping (ReminderCreationRequest) throws -> Void,
        @escaping () -> Void
    ) -> Void
    let onPresentItemEditor: (
        CalendarItemComposerMode,
        [EKCalendar],
        [EKCalendar],
        @escaping (CalendarEventCreationRequest) throws -> Void,
        @escaping (ReminderCreationRequest) throws -> Void,
        @escaping () -> Void
    ) -> Void
    let onPresentVacationGuide: (Date, @escaping (Date) -> Void) -> Void
    let onPresentWeatherDetailWindow: (WeatherForecastOverview, @escaping () -> Void) -> Void
    let onPresentPomodoroStatisticsWindow: (@escaping () -> Void) -> Void
    let onDismissEventDetailWindow: () -> Void
    let onDismissWeatherDetailWindow: () -> Void
    let onDismissPomodoroStatisticsWindow: () -> Void
    let onQuit: () -> Void

    @State private var itemsForSelectedDate: [CalendarItem] = []
    @State private var isLoadingEvents: Bool = false
    @State private var upcomingItems: [CalendarItem] = []
    @State private var isLoadingUpcomingPast: Bool = false
    @State private var isLoadingUpcomingFuture: Bool = false
    // 条数分页游标：下一页查询窗的边界锚点。未来游标=下一窗起点（从
    // 今天零点向上推进）；过去游标=下一窗上界（从今天零点向下推进）；
    // nil=该方向已探明尽头（设置上限/空窗/循环保护）。弹层每次打开由
    // 分节 onAppear 触发重置回第一页，不再跨打开保留窗口端点
    @State private var upcomingFutureCursor: Date?
    @State private var upcomingPastCursor: Date?
    // 分页重置代数：每次重置分页递增，「近期日程」分节据此把滚动位置
    // 显式拉回列表顶（数据重置后滚动偏移会残留）
    @State private var upcomingResetGeneration: Int = 0
    // 分方向请求竞态 ID：各方向入口自增、完成块校验并只复位自己的在途
    // 标记，两方向互不作废（下拉加载过去与底部哨兵加载未来可真并发）；
    // 重置/清空时统一递增两个 ID 作废所有在途加载
    @State private var upcomingPastRequestID = UUID()
    @State private var upcomingFutureRequestID = UUID()
    // 分方向页满复查标记：上一次页装配以页满收尾（未尽头）时置位，下一
    // 次装载的第一窗按同窗复查处理（复查窗零新条目不算过去端尽头），
    // 完成块按是否页满收尾回写；重置/清空时归 false
    @State private var isUpcomingPastResumingWindow = false
    @State private var isUpcomingFutureResumingWindow = false
    @State private var almanacDescriptor: AlmanacDescriptor?
    @State private var weatherDescriptor: WeatherDescriptor?
    @State private var isLoadingWeather: Bool = false
    @State private var weatherService = WeatherService(locationResolver: CoreLocationWeatherLocationResolver())
    @State private var weatherTask: Task<Void, Never>?
    @State private var weatherDetailTask: Task<Void, Never>?
    @State private var weatherRequestID = UUID()
    @State private var weatherDetailRequestID = UUID()
    @State private var lastWeatherRefreshTime: Date?
    @State private var lastWeatherRequestedDate: Date?
    @State private var isLoadingWeatherDetails = false
    @State private var isWeatherDetailPresented = false
    @State private var isPomodoroStatisticsPresented = false

    private let almanacService = AlmanacService()
    private let weatherAutoRefreshInterval: TimeInterval = 15 * 60

    /// 近期日程条数分页参数：每页条数、单窗查询跨度与单页窗口循环上限。
    /// 第一页从当天零点开始取 10 条（含今天全天事件），过去方向初始 0 条；
    /// 未来页从游标起按 30 天窗循环查询凑满一页或触达设置上限，过去页
    /// 对称（无下限，空窗即尽头）。
    static let upcomingPageSize = 10
    static let upcomingPageWindowDays = 30
    static let upcomingPageMaxWindows = 12

    /// 近期日程分页方向：未来页从游标向下游推进，过去页对称向上。
    enum UpcomingPageDirection {
        case past
        case future
    }

    /// 单窗分页切片结果（纯数据，便于单测断言）。
    struct UpcomingPageWindowSlice {
        // 本窗新取条目：已剔除已加载身份，统一升序存放（展示排序由
        // UpcomingSnapshot 负责）
        let takenItems: [CalendarItem]
        // 本窗查询结果中落入窗内的条目总数（去重前，供过去端空窗判定：
        // 全部重复只说明递归提醒跨窗重复返回，不代表历史尽头）
        let inRangeItemCount: Int
        // 本窗取完后本页是否已凑满页大小
        let isPageFull: Bool
    }

    /// 分页切片与游标推进（纯静态函数，便于单测）：输入一个 EventKit
    /// 窗口查询结果（条目序列）与当前游标上下文，输出本窗取走的条目、
    /// 下一窗游标与是否尽头。窗口为半开区间 [windowStart, windowEnd)，
    /// 与 fetchUpcomingCalendarItems 的谓词与过滤语义一致。
    /// - Parameters:
    ///   - direction: 分页方向（未来/过去）
    ///   - windowItems: 本窗查询返回条目（EventService 已按开始时间升序）
    ///   - windowStart/windowEnd: 本窗半开区间两端，来自调用方循环裁剪
    ///   - collectedCount: 本页已凑条数
    ///   - loadedIdentifiers: 已加载条目身份集合（selectionIdentifier）；
    ///     页界同刻条目与页满后的同窗复查都靠它去重，保证不重不漏
    ///   - pageSize: 页大小
    ///   - futureLimitEnd: 未来方向的时间上限（设置换算的绝对日期），
    ///     nil 表示不限制；过去方向无下限，不使用该参数
    ///   - isResumingWindow: 本窗是否为页满中断后的同窗复查；复查窗零
    ///     新条目只代表窗口耗尽，不算过去端尽头
    /// - Returns: 本窗切片、下一窗游标（nil=尽头）、是否已探明尽头
    /// - Note: 页满时游标停在当前窗内（未来=窗起点、过去=窗上界），下一
    ///   页复查同一窗并用身份去重续接页界（等价于「页游标=已取条目极值
    ///   之后」，且同刻条目可跨页不重不漏）；窗口耗尽未凑满时未来游标
    ///   推进到窗尾（触达上限即尽头，空窗不算），过去游标推进到窗头
    ///   （空窗即尽头）。
    /// - Note: 纯函数无隔离依赖，显式 nonisolated 供非主线程上下文与
    ///   单测直接调用。
    nonisolated static func advanceUpcomingPage(
        direction: UpcomingPageDirection,
        windowItems: [CalendarItem],
        windowStart: Date,
        windowEnd: Date,
        collectedCount: Int,
        loadedIdentifiers: Set<String>,
        pageSize: Int,
        futureLimitEnd: Date?,
        isResumingWindow: Bool
    ) -> (slice: UpcomingPageWindowSlice, nextWindowStart: Date?, isExhausted: Bool) {
        // 区间过滤 + 剔除已加载身份：切片自防护一次区间语义，复查与
        // 同刻页界靠身份集合去重
        let inRangeItems = windowItems.filter { item in
            guard let startDate = item.startDate else { return false }
            return startDate >= windowStart && startDate < windowEnd
        }
        let freshItems = inRangeItems.filter {
            !loadedIdentifiers.contains($0.selectionIdentifier)
        }
        let remaining = pageSize - collectedCount
        let takeCount = max(0, min(remaining, freshItems.count))
        // 未来向取最早的一批（升序头部）；过去向取离游标最近的一批
        // （升序尾段，即开始时间最大者），两向输出均保持升序存放
        let taken: [CalendarItem]
        switch direction {
        case .future:
            taken = Array(freshItems.prefix(takeCount))
        case .past:
            taken = Array(freshItems.suffix(takeCount))
        }
        let slice = UpcomingPageWindowSlice(
            takenItems: taken,
            inRangeItemCount: inRangeItems.count,
            isPageFull: collectedCount + taken.count >= pageSize
        )

        // 页满：游标停在当前窗内，下一页复查同一窗续接页界——未来窗游
        // 标=窗起点，复查游标即 windowStart；过去窗游标=窗上界，复查游
        // 标须为 windowEnd（若回退到 windowStart，下次查询窗会跳到更早
        // 一窗，本窗剩余条目永不复查，且下一窗为空会误判历史尽头）
        if slice.isPageFull {
            let resumeCursor = direction == .past ? windowEnd : windowStart
            return (slice, resumeCursor, false)
        }

        switch direction {
        case .future:
            // 未来游标推进到窗尾；触达设置上限即尽头（空窗不算尽头，
            // 继续向更远的窗推进，由单页窗口循环上限兜底）
            if let futureLimitEnd, windowEnd >= futureLimitEnd {
                return (slice, nil, true)
            }
            return (slice, windowEnd, false)
        case .past:
            // 过去端空窗即尽头（沿用「带不回条目即历史起点」启发式）；
            // 复查窗或仅有递归提醒重复的窗推进游标继续
            if inRangeItems.isEmpty, !isResumingWindow {
                return (slice, nil, true)
            }
            return (slice, windowStart, false)
        }
    }

    var body: some View {
        popoverContent
            .onAppear {
                timeRefreshCoordinator.refreshNow()
                eventService.checkAuthorizationStatus()
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                // 近期日程的首载由「近期日程」分节 onAppear 触发（内容视图
                // 重挂载即触发），那里同时负责重置分页与回滚滚动位置
                refreshInfoStrips()
            }
            .onReceive(eventService.$isAuthorized.dropFirst()) { _ in
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                resetUpcomingPaginationAndLoadFirstPage()
            }
            .onReceive(eventService.$remindersAuthorized.dropFirst()) { isAuthorized in
                if isAuthorized {
                    eventService.fetchReminderCalendars()
                }
                refreshEventsForCurrentSelection()
                resetUpcomingPaginationAndLoadFirstPage()
            }
            .onReceive(settingsStore.$menuBarPreferences.dropFirst()) { _ in
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                resetUpcomingPaginationAndLoadFirstPage()
                refreshInfoStrips()
            }
            .onReceive(eventService.$storeChangeRevision.dropFirst()) { _ in
                refreshEventsForCurrentSelection()
                resetUpcomingPaginationAndLoadFirstPage()
            }
            .onReceive(viewModel.$selectedDate.dropFirst()) { newDate in
                if let date = newDate {
                    loadEvents(for: date)
                    refreshInfoStrips()
                } else {
                    clearLoadedEvents()
                }
                // 近期日程内容与选中日期无关，分页状态不随选日变化重置
            }
            .onReceive(timeRefreshCoordinator.$currentDate) { currentDate in
                guard shouldAutoRefreshWeather(at: currentDate) else { return }
                refreshWeather(for: viewModel.selectedDate ?? currentDate)
            }
            .onReceive(timeRefreshCoordinator.$dayChangeRevision.dropFirst()) { _ in
                viewModel.syncCurrentDaySelectionIfNeeded(calendar: displayCalendar)
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                // 跨天后分页基准（今天零点）前移，回到第一页重新开始
                resetUpcomingPaginationAndLoadFirstPage()
                refreshInfoStrips()
            }
            .onDisappear {
                cancelWeatherLoad()
                dismissWeatherDetail()
                dismissPomodoroStatistics()
            }
    }

    private var popoverContent: some View {
        let displayedMonthDays = monthDays
        let selectedDateSummary = makeSelectedDateSummary(visibleDays: displayedMonthDays)

        return CalendarPopoverView(
            displayedMonth: viewModel.displayedMonth,
            displayedYear: viewModel.displayedYear,
            displayedMonthNumber: viewModel.displayedMonthNumber,
            currentYear: viewModel.currentYear,
            currentMonthNumber: viewModel.currentMonthNumber,
            selectionMode: viewModel.selectionMode,
            weekdaySymbols: viewModel.weekdaySymbols(using: displayCalendar),
            weekendIndices: Self.weekendColumnIndices(for: displayCalendar),
            monthDays: displayedMonthDays,
            highlightWeekends: settingsStore.menuBarPreferences.highlightWeekends,
            showEvents: settingsStore.menuBarPreferences.showEvents,
            emptyStateText: settingsStore.menuBarPreferences.eventListEmptyStateText,
            showUpcomingSection: settingsStore.menuBarPreferences.showUpcomingSection,
            upcomingItems: upcomingItems,
            isLoadingUpcomingPast: isLoadingUpcomingPast,
            isLoadingUpcomingFuture: isLoadingUpcomingFuture,
            hasMoreUpcomingPast: upcomingPastCursor != nil,
            hasMoreUpcomingFuture: upcomingFutureCursor != nil,
            upcomingDefaultExpanded: settingsStore.menuBarPreferences.upcomingDefaultExpanded,
            upcomingResetGeneration: upcomingResetGeneration,
            selectedDate: viewModel.selectedDate,
            items: itemsForSelectedDate,
            selectedEventIdentifier: viewModel.selectedEventIdentifier,
            isLoadingEvents: isLoadingEvents,
            timeRefreshCoordinator: timeRefreshCoordinator,
            selectedDateSummary: selectedDateSummary,
            almanac: almanacDescriptor,
            showAlmanac: settingsStore.menuBarPreferences.showAlmanac,
            weather: weatherDescriptor,
            isLoadingWeather: isLoadingWeather,
            showWeather: settingsStore.menuBarPreferences.showWeather,
            isWeatherDetailPresented: isWeatherDetailPresented,
            isLoadingWeatherDetails: isLoadingWeatherDetails,
            pomodoroState: pomodoroTimer.state,
            pomodoroPreferences: settingsStore.pomodoroPreferences,
            showVacationGuideButton: showVacationGuideButton,
            isVacationGuideEnabled: isVacationGuideEnabled,
            vacationGuideDisabledReason: vacationGuideDisabledReason,
            canCreateEvent: canCreateEvent,
            canCreateReminder: canCreateReminder,
            onPreviousMonth: {
                viewModel.showPreviousMonth(using: displayCalendar)
            },
            onNextMonth: {
                viewModel.showNextMonth(using: displayCalendar)
            },
            onSelectYear: {
                viewModel.enterYearSelection()
            },
            onSelectMonth: {
                viewModel.enterMonthSelection()
            },
            onSelectYearValue: { year in
                viewModel.selectYear(year, calendar: displayCalendar)
            },
            onSelectMonthValue: { month in
                viewModel.selectMonth(month, calendar: displayCalendar)
            },
            onDismissPicker: {
                viewModel.dismissPicker()
            },
            onSelectDate: handleDateSelection,
            onSelectEvent: { event in
                handleEventSelection(event)
            },
            onToggleReminder: { reminder in
                handleToggleReminder(reminder)
            },
            onOpenReminder: { reminder in
                handleOpenReminder(reminder)
            },
            onCreateItem: {
                handleCreateItem()
            },
            onCreateEventAt: { timeRange in
                handleCreateItem(initialTimeRange: timeRange)
            },
            onResetUpcomingPagination: resetUpcomingPaginationAndLoadFirstPage,
            onLoadMoreUpcomingPast: handleLoadMoreUpcomingPast,
            onLoadMoreUpcomingFuture: handleLoadMoreUpcomingFuture,
            onOpenWeatherDetails: handleOpenWeatherDetails,
            onOpenVacationGuide: handleOpenVacationGuide,
            onResetToToday: handleResetToToday,
            onOpenPomodoroStatistics: handleOpenPomodoroStatistics,
            onStartPomodoroFocus: {
                pomodoroTimer.startFocus()
            },
            onPausePomodoro: {
                pomodoroTimer.pause()
            },
            onResumePomodoro: {
                pomodoroTimer.resume()
            },
            onSkipPomodoro: {
                pomodoroTimer.skip()
            },
            onEndPomodoro: {
                pomodoroTimer.end()
            },
            onQuit: onQuit
        )
    }

    private func handleDateSelection(_ date: Date) {
        dismissEventDetail()
        viewModel.selectDate(date)
    }

    private func handleOpenVacationGuide() {
        onPresentVacationGuide(viewModel.displayedMonth) { date in
            dismissEventDetail()
            viewModel.showMonth(containing: date, calendar: displayCalendar)
            viewModel.selectDate(date)
        }
    }

    private func handleResetToToday() {
        dismissEventDetail()
        viewModel.resetToToday()
        viewModel.selectDate(timeRefreshCoordinator.currentDate, followsCurrentDay: true)
    }

    private func refreshInfoStrips() {
        let date = viewModel.selectedDate ?? timeRefreshCoordinator.currentDate

        if settingsStore.menuBarPreferences.showAlmanac {
            almanacDescriptor = almanacService.describe(date: date)
        } else {
            almanacDescriptor = nil
        }

        refreshWeather(for: date)
    }

    private func refreshWeather(for date: Date) {
        guard settingsStore.menuBarPreferences.showWeather else {
            clearWeather()
            return
        }

        let expectedLocation = preferredWeatherLocation
        let expectedProviderConfiguration = settingsStore.weatherProviderConfiguration()
        if weatherService.manualLocation != expectedLocation
            || weatherService.providerConfiguration != expectedProviderConfiguration {
            dismissWeatherDetail()
            cancelWeatherLoad()
            weatherService = WeatherService(
                manualLocation: expectedLocation,
                providerConfiguration: expectedProviderConfiguration,
                locationResolver: CoreLocationWeatherLocationResolver()
            )
        }

        cancelWeatherLoad()
        weatherDescriptor = nil
        isLoadingWeather = true
        lastWeatherRefreshTime = timeRefreshCoordinator.currentDate
        lastWeatherRequestedDate = date

        let requestID = UUID()
        weatherRequestID = requestID
        let requestedDate = date
        let requestedCalendar = displayCalendar
        let service = weatherService

        weatherTask = Task {
            let descriptor = await service.describe(date: requestedDate, calendar: requestedCalendar)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard weatherRequestID == requestID else { return }
                guard settingsStore.menuBarPreferences.showWeather else {
                    clearWeather()
                    return
                }
                guard weatherService.manualLocation == expectedLocation else { return }
                guard weatherService.providerConfiguration == expectedProviderConfiguration else { return }

                let currentSelectedDate = viewModel.selectedDate ?? timeRefreshCoordinator.currentDate
                guard requestedCalendar.isDate(currentSelectedDate, inSameDayAs: requestedDate) else { return }

                weatherDescriptor = descriptor.hasContent ? descriptor : nil
                isLoadingWeather = false
                weatherTask = nil
            }
        }
    }

    private func clearWeather() {
        cancelWeatherLoad()
        dismissWeatherDetail()
        weatherDescriptor = nil
        lastWeatherRefreshTime = nil
        lastWeatherRequestedDate = nil
    }

    private func cancelWeatherLoad() {
        weatherTask?.cancel()
        weatherTask = nil
        weatherService.cancelInFlightSnapshot()
        weatherRequestID = UUID()
        isLoadingWeather = false
    }

    private func handleOpenWeatherDetails() {
        guard settingsStore.menuBarPreferences.showWeather else { return }
        guard weatherDescriptor?.hasContent == true else { return }

        if isWeatherDetailPresented {
            dismissWeatherDetail()
            return
        }

        dismissEventDetail()
        loadWeatherDetails()
    }

    private func handleOpenPomodoroStatistics() {
        if isPomodoroStatisticsPresented {
            dismissPomodoroStatistics()
            return
        }

        dismissEventDetail()
        dismissWeatherDetail()
        isPomodoroStatisticsPresented = true
        onPresentPomodoroStatisticsWindow {
            isPomodoroStatisticsPresented = false
        }
    }

    private func dismissPomodoroStatistics() {
        isPomodoroStatisticsPresented = false
        onDismissPomodoroStatisticsWindow()
    }

    private func loadWeatherDetails() {
        guard !isLoadingWeatherDetails else { return }

        let expectedLocation = preferredWeatherLocation
        let expectedProviderConfiguration = settingsStore.weatherProviderConfiguration()
        let requestID = UUID()
        let requestedCalendar = displayCalendar
        let service = weatherService

        weatherDetailRequestID = requestID
        isLoadingWeatherDetails = true
        weatherDetailTask?.cancel()
        weatherDetailTask = Task {
            let overview = await service.forecastOverview(days: 10, calendar: requestedCalendar)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard weatherDetailRequestID == requestID else { return }
                guard settingsStore.menuBarPreferences.showWeather else {
                    dismissWeatherDetail()
                    return
                }
                guard weatherService.manualLocation == expectedLocation else { return }
                guard weatherService.providerConfiguration == expectedProviderConfiguration else { return }

                isLoadingWeatherDetails = false
                weatherDetailTask = nil

                guard overview.hasContent else { return }
                isWeatherDetailPresented = true
                onPresentWeatherDetailWindow(overview) {
                    isWeatherDetailPresented = false
                }
            }
        }
    }

    private func dismissWeatherDetail() {
        weatherDetailTask?.cancel()
        weatherDetailTask = nil
        weatherDetailRequestID = UUID()
        isLoadingWeatherDetails = false
        isWeatherDetailPresented = false
        onDismissWeatherDetailWindow()
    }

    private func loadEvents(for date: Date) {
        let preferences = settingsStore.menuBarPreferences

        guard preferences.showEvents else {
            clearLoadedEvents()
            return
        }

        guard preferences.hasEnabledEventSources else {
            clearLoadedEvents()
            return
        }

        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }

        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        isLoadingEvents = true
        let requestedDate = date
        Task {
            let items = await eventService.fetchCalendarItems(
                for: date,
                enabledCalendarIDs: preferences.enabledCalendarIDs,
                enabledReminderCalendarIDs: preferences.enabledReminderCalendarIDs,
                showCalendarEvents: preferences.showCalendarEvents,
                showReminders: preferences.showReminders
            )
            await MainActor.run {
                guard viewModel.selectedDate == requestedDate else { return }
                itemsForSelectedDate = items
                syncSelectedEvent(with: items)
                isLoadingEvents = false
            }
        }
    }

    private func refreshEventsForCurrentSelection(selectingTodayIfNeeded: Bool = false) {
        let preferences = settingsStore.menuBarPreferences

        guard preferences.showEvents else {
            clearLoadedEvents()
            return
        }

        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }

        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        if let selectedDate = viewModel.selectedDate {
            loadEvents(for: selectedDate)
        } else if selectingTodayIfNeeded {
            viewModel.selectDate(timeRefreshCoordinator.currentDate, followsCurrentDay: true)
        }
    }

    private func clearLoadedEvents() {
        itemsForSelectedDate = []
        isLoadingEvents = false
        viewModel.clearSelectedEvent()
        onDismissEventDetailWindow()
    }

    /// 重置分页状态并加载第一页：清空已加载条目、两端游标回到当天零点、
    /// 递增重置代数（分节据此把滚动位置拉回列表顶），然后从当天开始
    /// （含今天全天）加载未来方向第一页 10 条；过去方向初始 0 条，仅
    /// 下拉过拉时加载。弹层每次打开由分节 onAppear 触发；授权/提醒授权/
    /// 设置/store 变更与跨天的重取也统一走本方法（数据源变化后从第一页
    /// 重新开始，语义可预期，推翻此前「窗口端点跨打开保留」的模型）。
    private func resetUpcomingPaginationAndLoadFirstPage() {
        let preferences = settingsStore.menuBarPreferences

        guard preferences.showUpcomingSection else {
            clearLoadedUpcoming()
            return
        }

        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }

        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        // 重置先于首载：递增两方向请求 ID 作废所有在途加载，旧请求结果
        // 由各自方向的竞态守卫丢弃；页满复查标记随游标一并归位（首屏
        // 第一页不是复查）
        upcomingPastRequestID = UUID()
        upcomingFutureRequestID = UUID()
        isUpcomingPastResumingWindow = false
        isUpcomingFutureResumingWindow = false
        upcomingItems = []
        isLoadingUpcomingPast = false
        isLoadingUpcomingFuture = false
        upcomingFutureCursor = displayCalendar.startOfDay(
            for: timeRefreshCoordinator.currentDate
        )
        upcomingPastCursor = displayCalendar.startOfDay(
            for: timeRefreshCoordinator.currentDate
        )
        upcomingResetGeneration += 1
        loadUpcomingPage(direction: .future)
    }

    /// 加载一页近期日程：按方向从游标起做「30 天窗循环查询 + 切片推进」，
    /// 直到凑满页大小、探明尽头或达到单页窗口循环上限（12 窗，约 360 天，
    /// 防极端数据下无限查询）。加载中同方向忽略重复触发，两方向互不互斥、
    /// 可真并发（下拉加载过去与底部哨兵加载未来各自的进度行/哨兵互不干
    /// 扰）；请求 ID 按方向分域自增与校验，跨方向的在途加载互不作废，
    /// 重置产生的过期结果由各自方向的竞态守卫兜底丢弃。EventKit 查询
    /// 薄层沿用 fetchUpcomingCalendarItems 的既有谓词与过滤（半开区间
    /// 窗口逐窗平铺）。
    private func loadUpcomingPage(direction: UpcomingPageDirection) {
        let preferences = settingsStore.menuBarPreferences
        guard let startCursor = direction == .future
            ? upcomingFutureCursor
            : upcomingPastCursor else {
            return
        }

        // 同方向 in-flight 防重：加载中忽略重复触发；请求 ID 写入本方向
        // 竞态域，另一方向的自增与本方向无关；页满复查标记按方向读取
        // 快照（跨拉取传递，由上一次完成块回写）
        let requestID: UUID
        let startIsResumingWindow: Bool
        switch direction {
        case .past:
            guard !isLoadingUpcomingPast else { return }
            isLoadingUpcomingPast = true
            requestID = UUID()
            upcomingPastRequestID = requestID
            startIsResumingWindow = isUpcomingPastResumingWindow
        case .future:
            guard !isLoadingUpcomingFuture else { return }
            isLoadingUpcomingFuture = true
            requestID = UUID()
            upcomingFutureRequestID = requestID
            startIsResumingWindow = isUpcomingFutureResumingWindow
        }

        let now = timeRefreshCoordinator.currentDate
        // 时间范围上限设置（30/90/180/全部）换算为未来方向绝对尽头；
        // 0 表示不限制。过去方向无下限，不使用该边界
        let futureLimitEnd: Date? = preferences.upcomingDayLimit > 0
            ? displayCalendar.date(byAdding: .day, value: preferences.upcomingDayLimit, to: now)
            : nil

        // 已加载身份快照：页界同刻条目与页满后同窗复查的去重依据
        var loadedIdentifiers = Set(upcomingItems.map(\.selectionIdentifier))
        let enabledCalendarIDs = preferences.upcomingEnabledCalendarIDs
        let includeReminders = preferences.upcomingIncludeReminders
        let enabledReminderCalendarIDs = preferences.upcomingEnabledReminderCalendarIDs
        let calendar = displayCalendar
        let service = eventService

        Task {
            var collected: [CalendarItem] = []
            var cursor = startCursor
            // 首窗是否为页满中断后的同窗复查（跨拉取传递的快照）；
            // 窗间传递由下方按 isPageFull 维护
            var isResumingWindow = startIsResumingWindow
            var isExhausted = false
            var queriedWindowCount = 0

            while !isExhausted,
                  collected.count < RootPopoverView.upcomingPageSize,
                  queriedWindowCount < RootPopoverView.upcomingPageMaxWindows {
                // 窗口边界：未来窗 [cursor, cursor+30天) 裁剪到设置上限；
                // 过去窗 [cursor-30天, cursor)，游标即窗上界
                let windowStart: Date
                let windowEnd: Date
                switch direction {
                case .future:
                    windowStart = cursor
                    var end = calendar.date(
                        byAdding: .day,
                        value: RootPopoverView.upcomingPageWindowDays,
                        to: cursor
                    ) ?? cursor
                    if let futureLimitEnd, end > futureLimitEnd {
                        end = futureLimitEnd
                    }
                    windowEnd = end
                case .past:
                    windowEnd = cursor
                    windowStart = calendar.date(
                        byAdding: .day,
                        value: -RootPopoverView.upcomingPageWindowDays,
                        to: cursor
                    ) ?? cursor
                }
                guard windowEnd > windowStart else {
                    isExhausted = true
                    break
                }

                queriedWindowCount += 1
                let windowItems = await service.fetchUpcomingCalendarItems(
                    pastStart: windowStart,
                    futureEnd: windowEnd,
                    enabledCalendarIDs: enabledCalendarIDs,
                    includeReminders: includeReminders,
                    enabledReminderCalendarIDs: enabledReminderCalendarIDs
                )
                let step = RootPopoverView.advanceUpcomingPage(
                    direction: direction,
                    windowItems: windowItems,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    collectedCount: collected.count,
                    loadedIdentifiers: loadedIdentifiers,
                    pageSize: RootPopoverView.upcomingPageSize,
                    futureLimitEnd: futureLimitEnd,
                    isResumingWindow: isResumingWindow
                )
                collected.append(contentsOf: step.slice.takenItems)
                for item in step.slice.takenItems {
                    loadedIdentifiers.insert(item.selectionIdentifier)
                }
                // 页满后下一轮为同窗复查，复查窗零新条目不算过去端尽头
                isResumingWindow = step.slice.isPageFull
                if let nextWindowStart = step.nextWindowStart {
                    cursor = nextWindowStart
                }
                isExhausted = step.isExhausted
            }

            // 循环上限触达仍未凑满：返回已有并视为尽头（游标置 nil）
            let hitWindowCap = !isExhausted
                && collected.count < RootPopoverView.upcomingPageSize
            let nextCursor: Date? = (isExhausted || hitWindowCap) ? nil : cursor
            // 页满收尾（未尽头）时游标停在窗内，下一次装载的第一窗为
            // 同窗复查；尽头/触达上限收尾游标为 nil，标记归 false
            let endedWithPageFull = nextCursor != nil
                && collected.count >= RootPopoverView.upcomingPageSize

            await MainActor.run {
                // 只校验本方向竞态域：另一方向入口自增自己的 ID 不作废
                // 本方向结果，先发方向不会被后发方向连带跳过复位
                switch direction {
                case .past:
                    guard upcomingPastRequestID == requestID else { return }
                    upcomingPastCursor = nextCursor
                    isUpcomingPastResumingWindow = endedWithPageFull
                    isLoadingUpcomingPast = false
                case .future:
                    guard upcomingFutureRequestID == requestID else { return }
                    upcomingFutureCursor = nextCursor
                    isUpcomingFutureResumingWindow = endedWithPageFull
                    isLoadingUpcomingFuture = false
                }
                upcomingItems.append(contentsOf: collected)
            }
        }
    }

    /// 下拉过拉触发：向过去加载一页（每页 10 条）。过去端已探明尽头
    /// （游标 nil）或加载中时，页装配入口直接忽略触发。
    private func handleLoadMoreUpcomingPast() {
        loadUpcomingPage(direction: .past)
    }

    /// 底部哨兵触发：向未来加载下一页，防重语义同过去端。
    private func handleLoadMoreUpcomingFuture() {
        loadUpcomingPage(direction: .future)
    }

    private func clearLoadedUpcoming() {
        upcomingPastRequestID = UUID()
        upcomingFutureRequestID = UUID()
        isUpcomingPastResumingWindow = false
        isUpcomingFutureResumingWindow = false
        upcomingItems = []
        isLoadingUpcomingPast = false
        isLoadingUpcomingFuture = false
        upcomingFutureCursor = nil
        upcomingPastCursor = nil
    }

    private func syncSelectedEvent(with items: [CalendarItem]) {
        guard let selectedIdentifier = viewModel.selectedEventIdentifier else { return }
        let found = items.contains { item in
            return item.selectionIdentifier == selectedIdentifier
        }
        guard found else {
            viewModel.clearSelectedEvent()
            onDismissEventDetailWindow()
            return
        }
    }

    private func handleEventSelection(_ event: EKEvent) {
        let shouldPresent = viewModel.toggleEventSelection(identifier: event.selectionIdentifier)
        if shouldPresent {
            onPresentEventDetailWindow(
                event,
                { event in
                    handleEditEvent(event)
                },
                { event in
                    handleDeleteEvent(event)
                },
                {
                    viewModel.clearSelectedEvent()
                }
            )
        } else {
            onDismissEventDetailWindow()
        }
    }

    private func handleToggleReminder(_ reminder: EKReminder) {
        do {
            try eventService.toggleReminderCompletion(reminder)
            refreshEventsForCurrentSelection()
            // 已完成的提醒直接从已加载分页中移除；分页游标与滚动位置不动，
            // 全量重取留给下一次打开或数据源刷新触发
            let toggledIdentifier = CalendarItem.reminder(reminder).selectionIdentifier
            upcomingItems.removeAll { $0.selectionIdentifier == toggledIdentifier }
        } catch {
            print("Failed to toggle reminder completion: \(error)")
        }
    }

    private func handleOpenReminder(_ reminder: EKReminder) {
        let item = CalendarItem.reminder(reminder)
        let shouldPresent = viewModel.toggleEventSelection(identifier: item.selectionIdentifier)
        if shouldPresent {
            onPresentReminderDetailWindow(
                reminder,
                { [weak eventService] toggledReminder in
                    do {
                        try eventService?.toggleReminderCompletion(toggledReminder)
                    } catch {
                        print("Failed to toggle reminder completion: \(error)")
                    }
                },
                { reminder in
                    handleEditReminder(reminder)
                },
                { reminder in
                    handleDeleteReminder(reminder)
                },
                {
                    viewModel.clearSelectedEvent()
                }
            )
        } else {
            onDismissEventDetailWindow()
        }
    }

    private func handleEditEvent(_ event: EKEvent) {
        guard event.calendar.allowsContentModifications else { return }

        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }
        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        onPresentItemEditor(
            .editEvent(event),
            eventService.writableCalendars,
            eventService.writableReminderCalendars,
            { request in
                try eventService.updateEvent(event, with: request)
                refreshEventsForCurrentSelection()
            },
            { _ in },
            {
                viewModel.clearSelectedEvent()
            }
        )
    }

    private func handleEditReminder(_ reminder: EKReminder) {
        guard reminder.calendar.allowsContentModifications else { return }

        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }
        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        onPresentItemEditor(
            .editReminder(reminder),
            eventService.writableCalendars,
            eventService.writableReminderCalendars,
            { _ in },
            { request in
                try eventService.updateReminder(reminder, with: request)
                refreshEventsForCurrentSelection()
            },
            {
                viewModel.clearSelectedEvent()
            }
        )
    }

    private func handleDeleteEvent(_ event: EKEvent) {
        do {
            try eventService.deleteEvent(event)
            dismissEventDetail()
            refreshEventsForCurrentSelection()
        } catch {
            presentDeletionError(title: L("Failed to Delete Event"), error: error)
        }
    }

    private func handleDeleteReminder(_ reminder: EKReminder) {
        do {
            try eventService.deleteReminder(reminder)
            dismissEventDetail()
            refreshEventsForCurrentSelection()
        } catch {
            presentDeletionError(title: L("Failed to Delete Reminder"), error: error)
        }
    }

    private func presentDeletionError(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func handleCreateItem(
        initialTimeRange: CalendarItemCreationTimeRange? = nil
    ) {
        guard let selectedDate = viewModel.selectedDate else { return }
        if initialTimeRange != nil, !canCreateEvent {
            return
        }
        let initialKind: CalendarItemCreationKind = initialTimeRange != nil || canCreateEvent
            ? .event
            : .reminder

        dismissEventDetail()
        if eventService.isAuthorized {
            eventService.fetchCalendars()
        }
        if eventService.remindersAuthorized {
            eventService.fetchReminderCalendars()
        }

        onPresentItemComposer(
            initialKind,
            selectedDate,
            initialTimeRange,
            eventService.writableCalendars,
            eventService.writableReminderCalendars,
            { request in
                _ = try eventService.createEvent(request)
                refreshEventsForCurrentSelection()
            },
            { request in
                _ = try eventService.createReminder(request)
                refreshEventsForCurrentSelection()
            },
            {
                viewModel.clearSelectedEvent()
            }
        )
    }

    private func dismissEventDetail() {
        viewModel.clearSelectedEvent()
        onDismissEventDetailWindow()
    }

    private var displayCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = settingsStore.menuBarPreferences.weekStart == .monday ? 2 : 1
        return calendar
    }

    private func makeSelectedDateSummary(visibleDays: [CalendarDay]) -> SelectedDateSummary {
        SelectedDateSummaryFactory(calendar: displayCalendar, registry: .live).make(
            selectedDate: viewModel.selectedDate,
            currentDate: timeRefreshCoordinator.currentDate,
            displayedMonth: viewModel.displayedMonth,
            preferences: settingsStore.menuBarPreferences,
            locale: AppLocalization.locale,
            showsLunarDate: LocaleFeatureAvailability.showLunarFeatures,
            offText: L("OFF"),
            workText: L("WRK"),
            visibleDays: visibleDays
        )
    }

    private var preferredWeatherLocation: WeatherLocation? {
        settingsStore.menuBarPreferences.locationMode == .manual
            ? settingsStore.menuBarPreferences.manualLocation
            : nil
    }

    private var canCreateEvent: Bool {
        settingsStore.menuBarPreferences.showEvents
            && settingsStore.menuBarPreferences.showCalendarEvents
            && eventService.isAuthorized
            && !eventService.writableCalendars.isEmpty
    }

    private var canCreateReminder: Bool {
        settingsStore.menuBarPreferences.showEvents
            && settingsStore.menuBarPreferences.showReminders
            && eventService.remindersAuthorized
            && !eventService.writableReminderCalendars.isEmpty
    }

    private func shouldAutoRefreshWeather(at currentDate: Date) -> Bool {
        guard settingsStore.menuBarPreferences.showWeather else { return false }
        guard weatherTask == nil else { return false }

        if let selectedDate = viewModel.selectedDate,
           let lastRequestedDate = lastWeatherRequestedDate,
           !displayCalendar.isDate(selectedDate, inSameDayAs: lastRequestedDate) {
            return false
        }

        guard let lastWeatherRefreshTime else { return true }
        return currentDate.timeIntervalSince(lastWeatherRefreshTime) >= weatherAutoRefreshInterval
    }

    private static func weekendColumnIndices(for calendar: Calendar) -> Set<Int> {
        let firstWeekday = calendar.firstWeekday
        let weekendDays = [1, 7]
        var indices = Set<Int>()
        for weekday in weekendDays {
            let adjustedIndex = (weekday - firstWeekday + 7) % 7
            indices.insert(adjustedIndex)
        }
        return indices
    }

    private var monthService: MonthCalendarService {
        MonthCalendarService(calendar: displayCalendar)
    }

    private var showVacationGuideButton: Bool {
        LocaleFeatureAvailability.showVacationGuideFeatures
            && settingsStore.menuBarPreferences.activeRegionIDs.contains("mainland-cn")
    }

    private var isVacationGuideEnabled: Bool {
        showVacationGuideButton && isHolidaySetEnabled("statutory-holidays")
    }

    private var vacationGuideDisabledReason: String? {
        guard showVacationGuideButton, !isVacationGuideEnabled else {
            return nil
        }

        return "请先在地区设置中启用法定节假日"
    }

    private func isHolidaySetEnabled(_ holidaySetID: String) -> Bool {
        let enabledSetIDs = settingsStore.menuBarPreferences.enabledHolidayIDs
        return enabledSetIDs.isEmpty || enabledSetIDs.contains(holidaySetID)
    }

    private var monthDays: [CalendarDay] {
        let factory = CalendarDayFactory(
            calendar: displayCalendar,
            registry: .live,
            now: { timeRefreshCoordinator.currentDate }
        )
        return (try? factory.makeMonthGrid(
            for: viewModel.displayedMonth,
            preferences: settingsStore.menuBarPreferences,
            selectedDate: viewModel.selectedDate
        )) ?? monthService.makeMonthGrid(for: viewModel.displayedMonth)
    }
}

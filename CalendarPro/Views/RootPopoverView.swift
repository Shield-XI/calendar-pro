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
    // 双向窗口端点：过去端点=今天零点向上游回溯 upcomingPastDays 天；
    // 未来端点=now 向下游扩展 upcomingFutureDays 天。@State 随弹层视图实例
    // 存活，用户已扩展的端点在弹层重开时保留，只重取数据不重置窗口
    @State private var upcomingPastDays: Int = 0
    @State private var upcomingFutureDays: Int = RootPopoverView.initialUpcomingWindowDays
    // 过去端达界标记：向过去扩窗带不回任何条目时置位，隐藏顶部哨兵；
    // 数据源或跨天变化可能带来更早的历史，相关触发点会复位该标记
    @State private var isUpcomingPastExhausted: Bool = false
    // 未来端达界标记：向未来扩窗带不回任何落在新扩展区间内的条目时置位，
    // 隐藏底部哨兵，与过去端对称；复位时机与过去端完全一致（数据源/设置
    // 变更与跨天）。已知取舍：未来端存在超过一个扩窗步幅（30 天）空档的
    // 事件时会提前停止加载，仅 dayLimit=0 无限制模式受影响
    @State private var isUpcomingFutureExhausted: Bool = false
    @State private var upcomingRequestID = UUID()
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

    /// 近期日程双向窗口的初始天数与每次滚动到端点自动加载的扩幅：
    /// 初始窗口为 [今天零点, now + 30 天]；上滚向过去扩 30 天（无天数硬
    /// 上限，探明历史起点即止），下滚向未来扩 30 天（受设置上限约束，
    /// 探明未来终点即止）
    static let initialUpcomingWindowDays = 30
    static let upcomingWindowStepDays = 30

    /// 未来端扩窗是否已探明终点（纯函数，便于单测）：本次扩窗带不回任何
    /// 开始日期落在新扩展区间 [previousFutureEnd, newFutureEnd) 内的条目
    /// 时为 true，与过去端「带不回更早条目即历史起点」的判定对称。
    /// 无开始日期的条目无法落入区间，不参与判定。
    static func isUpcomingFutureWindowExhausted(
        items: [CalendarItem],
        previousFutureEnd: Date,
        newFutureEnd: Date
    ) -> Bool {
        !items.contains { item in
            guard let startDate = item.startDate else { return false }
            return startDate >= previousFutureEnd && startDate < newFutureEnd
        }
    }

    var body: some View {
        popoverContent
            .onAppear {
                timeRefreshCoordinator.refreshNow()
                eventService.checkAuthorizationStatus()
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                loadUpcoming()
                refreshInfoStrips()
            }
            .onReceive(eventService.$isAuthorized.dropFirst()) { _ in
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                isUpcomingPastExhausted = false
                isUpcomingFutureExhausted = false
                loadUpcoming()
            }
            .onReceive(eventService.$remindersAuthorized.dropFirst()) { isAuthorized in
                if isAuthorized {
                    eventService.fetchReminderCalendars()
                }
                refreshEventsForCurrentSelection()
                isUpcomingPastExhausted = false
                isUpcomingFutureExhausted = false
                loadUpcoming()
            }
            .onReceive(settingsStore.$menuBarPreferences.dropFirst()) { _ in
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                isUpcomingPastExhausted = false
                isUpcomingFutureExhausted = false
                loadUpcoming()
                refreshInfoStrips()
            }
            .onReceive(eventService.$storeChangeRevision.dropFirst()) { _ in
                refreshEventsForCurrentSelection()
                isUpcomingPastExhausted = false
                isUpcomingFutureExhausted = false
                loadUpcoming()
            }
            .onReceive(viewModel.$selectedDate.dropFirst()) { newDate in
                if let date = newDate {
                    loadEvents(for: date)
                    refreshInfoStrips()
                } else {
                    clearLoadedEvents()
                }
                loadUpcoming()
            }
            .onReceive(timeRefreshCoordinator.$currentDate) { currentDate in
                guard shouldAutoRefreshWeather(at: currentDate) else { return }
                refreshWeather(for: viewModel.selectedDate ?? currentDate)
            }
            .onReceive(timeRefreshCoordinator.$dayChangeRevision.dropFirst()) { _ in
                viewModel.syncCurrentDaySelectionIfNeeded(calendar: displayCalendar)
                refreshEventsForCurrentSelection(selectingTodayIfNeeded: true)
                // 跨天后窗口基准（今天零点）前移，重置两端达界标记
                isUpcomingPastExhausted = false
                isUpcomingFutureExhausted = false
                loadUpcoming()
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
            upcomingWindowDays: upcomingFutureDays,
            upcomingDayLimit: settingsStore.menuBarPreferences.upcomingDayLimit,
            hasMoreUpcomingPast: !isUpcomingPastExhausted,
            hasMoreUpcomingFuture: !isUpcomingFutureExhausted,
            upcomingDefaultExpanded: settingsStore.menuBarPreferences.upcomingDefaultExpanded,
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

    /// 加载近期日程窗口数据；与 loadEvents 共用授权刷新与请求竞态保护。
    /// - Parameters:
    ///   - pastExtensionBoundary: 本次加载由「向过去扩窗」触发时传扩窗前的
    ///     窗口起点；结果在该边界之前没有任何条目时视为已探明历史起点，
    ///     停止继续向过去扩窗。其余触发的重取传 nil（保留既有达界标记，
    ///     避免弹层重开就重新向过去全量扩窗）。
    ///   - futureExtensionBoundary: 本次加载由「向未来扩窗」触发时传扩窗前
    ///     的窗口终点；结果在该边界到新窗口终点之间没有任何条目时视为已
    ///     探明未来终点，停止继续向未来扩窗（dayLimit=0 时哨兵否则会无限
    ///     循环触发）。其余触发的重取传 nil，语义与过去端对称。
    private func loadUpcoming(
        pastExtensionBoundary: Date? = nil,
        futureExtensionBoundary: Date? = nil
    ) {
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

        // 设置的上限缩小时收敛未来端点；上限 0 表示不限制
        if preferences.upcomingDayLimit > 0 {
            upcomingFutureDays = min(upcomingFutureDays, preferences.upcomingDayLimit)
        }

        let now = timeRefreshCoordinator.currentDate
        guard let pastStart = upcomingPastStart(from: now),
              let futureEnd = displayCalendar.date(
                  byAdding: .day,
                  value: upcomingFutureDays,
                  to: now
              ) else {
            return
        }

        // 每次全量重查当前窗口，两端加载标记一起置位；加载期间两端哨兵
        // 均被进度行替换，天然串行化，无并发扩窗竞态
        isLoadingUpcomingPast = true
        isLoadingUpcomingFuture = true
        let requestID = UUID()
        upcomingRequestID = requestID
        let enabledCalendarIDs = preferences.upcomingEnabledCalendarIDs
        let includeReminders = preferences.upcomingIncludeReminders
        let enabledReminderCalendarIDs = preferences.upcomingEnabledReminderCalendarIDs

        Task {
            let items = await eventService.fetchUpcomingCalendarItems(
                pastStart: pastStart,
                futureEnd: futureEnd,
                enabledCalendarIDs: enabledCalendarIDs,
                includeReminders: includeReminders,
                enabledReminderCalendarIDs: enabledReminderCalendarIDs
            )
            await MainActor.run {
                guard upcomingRequestID == requestID else { return }
                upcomingItems = items
                if let pastExtensionBoundary {
                    // 新扩的过去窗带不回任何条目，视为已到历史起点，隐藏顶部哨兵
                    let hasNewPastItems = items.contains {
                        ($0.startDate ?? .distantFuture) < pastExtensionBoundary
                    }
                    isUpcomingPastExhausted = !hasNewPastItems
                }
                if let futureExtensionBoundary {
                    // 新扩的未来窗带不回任何落在新扩展区间内的条目，视为已到
                    // 未来终点，隐藏底部哨兵
                    isUpcomingFutureExhausted = RootPopoverView
                        .isUpcomingFutureWindowExhausted(
                            items: items,
                            previousFutureEnd: futureExtensionBoundary,
                            newFutureEnd: futureEnd
                        )
                }
                isLoadingUpcomingPast = false
                isLoadingUpcomingFuture = false
            }
        }
    }

    /// 当前窗口的过去端点：今天零点起向上游回溯 upcomingPastDays 天。
    private func upcomingPastStart(from now: Date) -> Date? {
        displayCalendar.date(
            byAdding: .day,
            value: -upcomingPastDays,
            to: displayCalendar.startOfDay(for: now)
        )
    }

    /// 滚动到顶自动加载：窗口起点按固定步幅向过去扩展，不设天数硬上限，
    /// 探明历史起点（isUpcomingPastExhausted）后停止继续扩展；加载进行中
    /// 直接忽略触发，过期结果另有 upcomingRequestID 竞态守卫兜底丢弃。
    private func handleLoadMoreUpcomingPast() {
        guard !isLoadingUpcomingPast, !isUpcomingPastExhausted else { return }
        guard let boundary = upcomingPastStart(from: timeRefreshCoordinator.currentDate) else {
            return
        }
        upcomingPastDays += RootPopoverView.upcomingWindowStepDays
        loadUpcoming(pastExtensionBoundary: boundary)
    }

    /// 滚动到底自动加载：窗口终点按固定步幅扩展，直到设置的上限（0 为无
    /// 上限）或探明未来终点（isUpcomingFutureExhausted，防止无上限模式下
    /// 哨兵带不回新条目时无限循环触发）。加载进行中或已达界直接忽略触发，
    /// 从源头挡掉 in-flight 期间的重复调用；过期结果另有 upcomingRequestID
    /// 竞态守卫兜底丢弃。
    private func handleLoadMoreUpcomingFuture() {
        guard !isLoadingUpcomingFuture, !isUpcomingFutureExhausted else { return }

        let preferences = settingsStore.menuBarPreferences
        var nextWindow = upcomingFutureDays + RootPopoverView.upcomingWindowStepDays

        if preferences.upcomingDayLimit > 0 {
            nextWindow = min(nextWindow, preferences.upcomingDayLimit)
        }

        guard nextWindow > upcomingFutureDays else { return }
        // 扩窗前捕获旧窗口终点，供结果判定新条目是否落入扩展区间
        let previousFutureEnd = displayCalendar.date(
            byAdding: .day,
            value: upcomingFutureDays,
            to: timeRefreshCoordinator.currentDate
        )
        upcomingFutureDays = nextWindow
        loadUpcoming(futureExtensionBoundary: previousFutureEnd)
    }

    private func clearLoadedUpcoming() {
        upcomingRequestID = UUID()
        upcomingItems = []
        isLoadingUpcomingPast = false
        isLoadingUpcomingFuture = false
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
            loadUpcoming()
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

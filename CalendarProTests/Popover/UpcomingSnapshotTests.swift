import XCTest
import EventKit
@testable import CalendarPro

// 文件头：
// 职责：验证 UpcomingSnapshot 的按天分组纯函数（含双向窗口下的过去天组、
//       「昨天」天头与多天事件单次分组）、EventService 事件/提醒近期窗口
//       过滤（含递归展开近似），以及 RootPopoverView 条数分页的切片与
//       游标推进纯函数（跨窗凑页/同刻不重不漏/尽头判定）的行为。
// 输入：GMT 固定日历 + DateComponents 构造的固定日期与 EventKit 夹具。
// 输出：XCTest 断言结果。
// 依赖：XCTest、EventKit、@testable CalendarPro。

final class UpcomingSnapshotTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    // MARK: - UpcomingSnapshot 分组

    func testGroupsItemsByDayInAscendingOrder() {
        let now = makeDate(2026, 10, 16, 10, 0)
        let day3Event = makeEvent(
            start: makeDate(2026, 10, 19, 9, 0),
            end: makeDate(2026, 10, 19, 10, 0)
        )
        let todayEvent = makeEvent(
            start: makeDate(2026, 10, 16, 11, 0),
            end: makeDate(2026, 10, 16, 12, 0)
        )
        let tomorrowEvent = makeEvent(
            start: makeDate(2026, 10, 17, 15, 0),
            end: makeDate(2026, 10, 17, 16, 0)
        )

        let snapshot = UpcomingSnapshot.make(
            items: [day3Event, tomorrowEvent, todayEvent],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.dayGroups.count, 3)
        XCTAssertEqual(snapshot.totalItemCount, 3)
        XCTAssertEqual(
            snapshot.dayGroups.map(\.dayStart),
            [
                calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
                calendar.startOfDay(for: makeDate(2026, 10, 17, 0, 0)),
                calendar.startOfDay(for: makeDate(2026, 10, 19, 0, 0))
            ]
        )
        XCTAssertEqual(snapshot.dayGroups[0].items.count, 1)
        XCTAssertEqual(snapshot.dayGroups[1].items.count, 1)
        XCTAssertEqual(snapshot.dayGroups[2].items.count, 1)
    }

    func testGroupsSameDayItemsTogetherAndKeepsTimedOrderWithinDay() throws {
        let now = makeDate(2026, 10, 16, 10, 0)
        let afternoonEvent = makeEvent(
            start: makeDate(2026, 10, 17, 15, 0),
            end: makeDate(2026, 10, 17, 16, 0)
        )
        let morningReminder = CalendarItem.reminder(makeReminder(2026, 10, 17, 8, 30))
        let allDayEvent = makeAllDayEvent(
            start: makeDate(2026, 10, 17, 0, 0),
            end: makeDate(2026, 10, 17, 23, 59)
        )
        let morningEvent = makeEvent(
            start: makeDate(2026, 10, 17, 8, 0),
            end: makeDate(2026, 10, 17, 9, 0)
        )

        let snapshot = UpcomingSnapshot.make(
            items: [afternoonEvent, morningReminder, allDayEvent, morningEvent],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.dayGroups.count, 1)
        let group = try XCTUnwrap(snapshot.dayGroups.first)
        // 同一天内：全天在前，其余按开始时间升序
        XCTAssertEqual(group.items.count, 4)
        XCTAssertTrue(group.items[0].isAllDay)
        XCTAssertLessThanOrEqual(
            group.items[1].startDate!.timeIntervalSince1970,
            group.items[2].startDate!.timeIntervalSince1970
        )
        XCTAssertLessThanOrEqual(
            group.items[2].startDate!.timeIntervalSince1970,
            group.items[3].startDate!.timeIntervalSince1970
        )
    }

    func testEmptyInputYieldsNoGroups() {
        let snapshot = UpcomingSnapshot.make(
            items: [],
            now: makeDate(2026, 10, 16, 10, 0),
            calendar: calendar
        )

        XCTAssertTrue(snapshot.dayGroups.isEmpty)
        XCTAssertEqual(snapshot.totalItemCount, 0)
    }

    func testIgnoresItemsWithoutStartDate() {
        // dueDateComponents 为 nil 的提醒没有开始日期，快照应忽略
        let reminderWithoutDueDate = EKReminder(eventStore: EKEventStore())
        reminderWithoutDueDate.title = "无到期提醒"
        let snapshot = UpcomingSnapshot.make(
            items: [CalendarItem.reminder(reminderWithoutDueDate)],
            now: makeDate(2026, 10, 16, 10, 0),
            calendar: calendar
        )

        XCTAssertTrue(snapshot.dayGroups.isEmpty)
        XCTAssertEqual(snapshot.totalItemCount, 0)
    }

    // MARK: - 双向窗口分组（过去天组）

    func testPastEventsFormAscendingDayGroupsWithFutureGroups() {
        // 过去事件纳入分组，过去天组与未来天组共存且整体按天升序
        let now = makeDate(2026, 10, 16, 10, 0)
        let threeDaysAgo = makeEvent(
            start: makeDate(2026, 10, 13, 9, 0),
            end: makeDate(2026, 10, 13, 10, 0)
        )
        let yesterday = makeEvent(
            start: makeDate(2026, 10, 15, 9, 0),
            end: makeDate(2026, 10, 15, 10, 0)
        )
        let tomorrow = makeEvent(
            start: makeDate(2026, 10, 17, 9, 0),
            end: makeDate(2026, 10, 17, 10, 0)
        )

        let snapshot = UpcomingSnapshot.make(
            items: [tomorrow, threeDaysAgo, yesterday],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.dayGroups.count, 3)
        XCTAssertEqual(snapshot.totalItemCount, 3)
        XCTAssertEqual(
            snapshot.dayGroups.map(\.dayStart),
            [
                calendar.startOfDay(for: makeDate(2026, 10, 13, 0, 0)),
                calendar.startOfDay(for: makeDate(2026, 10, 15, 0, 0)),
                calendar.startOfDay(for: makeDate(2026, 10, 17, 0, 0))
            ]
        )
    }

    func testYesterdayGroupUsesYesterdayHeaderText() throws {
        let now = makeDate(2026, 10, 16, 10, 0)
        let yesterday = makeEvent(
            start: makeDate(2026, 10, 15, 9, 0),
            end: makeDate(2026, 10, 15, 10, 0)
        )

        let snapshot = UpcomingSnapshot.make(
            items: [yesterday],
            now: now,
            calendar: calendar
        )

        let group = try XCTUnwrap(snapshot.dayGroups.first)
        XCTAssertEqual(group.headerText, L("Recent Yesterday"))
    }

    func testMultiDayEventAppearsOnceInItsStartDayGroup() {
        // 多天事件只按开始日分组一次，不跨天重复展示
        let now = makeDate(2026, 10, 16, 10, 0)
        let multiDayEvent = makeEvent(
            start: makeDate(2026, 10, 12, 20, 0),
            end: makeDate(2026, 10, 14, 22, 0)
        )

        let snapshot = UpcomingSnapshot.make(
            items: [multiDayEvent],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.dayGroups.count, 1)
        XCTAssertEqual(
            snapshot.dayGroups.first?.dayStart,
            calendar.startOfDay(for: makeDate(2026, 10, 12, 0, 0))
        )
        XCTAssertEqual(snapshot.dayGroups.first?.items.count, 1)
        XCTAssertEqual(snapshot.totalItemCount, 1)
    }

    // MARK: - EventService.reminder(isDueWithin:) 近期窗口过滤

    @MainActor
    func testReminderWindowFilterAcceptsDueWithinWindow() {
        let reminder = makeReminder(2026, 10, 17, 9, 0)

        let isDue = EventService.reminder(
            reminder,
            isDueWithin: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            windowEnd: makeDate(2026, 10, 19, 0, 0),
            calendar: calendar
        )

        XCTAssertTrue(isDue)
    }

    @MainActor
    func testReminderWindowFilterRejectsDueBeforeWindowStart() {
        let reminder = makeReminder(2026, 10, 15, 9, 0)

        let isDue = EventService.reminder(
            reminder,
            isDueWithin: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            windowEnd: makeDate(2026, 10, 19, 0, 0),
            calendar: calendar
        )

        XCTAssertFalse(isDue)
    }

    @MainActor
    func testReminderWindowFilterExpandsDailyRecurrenceIntoWindow() {
        // 基准到期日早于窗口起点，递归规则为每日一次，应近似展开命中窗口
        let reminder = makeReminder(2026, 10, 1, 8, 0)
        reminder.recurrenceRules = [
            EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        ]

        let isDue = EventService.reminder(
            reminder,
            isDueWithin: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            windowEnd: makeDate(2026, 10, 19, 0, 0),
            calendar: calendar
        )

        XCTAssertTrue(isDue)
    }

    @MainActor
    func testReminderWindowFilterRejectsWeeklyRecurrenceOutsideWindow() {
        // 每周五重复的提醒，窗口内没有周五时应被过滤
        let reminder = makeReminder(2026, 10, 9, 8, 0)
        reminder.recurrenceRules = [
            EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        ]

        // 2026-10-16(周五) ~ 2026-10-19(周一)：窗口含周五，改用不含周五的窗口验证
        let windowStart = calendar.startOfDay(for: makeDate(2026, 10, 17, 0, 0))
        let windowEnd = makeDate(2026, 10, 22, 0, 0)

        let isDue = EventService.reminder(
            reminder,
            isDueWithin: windowStart,
            windowEnd: windowEnd,
            calendar: calendar
        )

        XCTAssertFalse(isDue)
    }

    // MARK: - EventService.event(isWithinUpcomingWindow:) 近期窗口过滤

    @MainActor
    func testEventWindowFilterExcludesMultiDayEventStartedBeforeWindowStart() {
        // 昨天开始、今天未结束：重叠语义谓词会查出，但开始早于窗口起点应
        // 排除，多天事件只在其开始日所在的窗口内展示一次
        let event = makeEKEvent(
            start: makeDate(2026, 10, 15, 20, 0),
            end: makeDate(2026, 10, 16, 12, 0)
        )

        let isIncluded = EventService.event(
            event,
            isWithinUpcomingWindow: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            enabledCalendarIDs: []
        )

        XCTAssertFalse(isIncluded)
    }

    @MainActor
    func testEventWindowFilterExcludesMultiDayEventSpanningWindowStart() {
        let event = makeEKEvent(
            start: makeDate(2026, 10, 15, 20, 0),
            end: makeDate(2026, 10, 17, 12, 0)
        )

        let isIncluded = EventService.event(
            event,
            isWithinUpcomingWindow: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            enabledCalendarIDs: []
        )

        XCTAssertFalse(isIncluded)
    }

    @MainActor
    func testEventWindowFilterIncludesEventStartedTodayAfterWindowStart() {
        // 今天零点后开始的事件应保留；双向窗口下已结束的当天事件同样纳入
        let event = makeEKEvent(
            start: makeDate(2026, 10, 16, 8, 0),
            end: makeDate(2026, 10, 16, 12, 0)
        )

        let isIncluded = EventService.event(
            event,
            isWithinUpcomingWindow: calendar.startOfDay(for: makeDate(2026, 10, 16, 0, 0)),
            enabledCalendarIDs: []
        )

        XCTAssertTrue(isIncluded)
    }

    @MainActor
    func testEventWindowFilterIncludesPastEventWithinExtendedWindow() {
        // 窗口向过去扩展后，窗口内已结束的事件应纳入（上滚查看过去日程）
        let event = makeEKEvent(
            start: makeDate(2026, 10, 12, 9, 0),
            end: makeDate(2026, 10, 12, 10, 0)
        )

        let isIncluded = EventService.event(
            event,
            isWithinUpcomingWindow: calendar.startOfDay(for: makeDate(2026, 10, 10, 0, 0)),
            enabledCalendarIDs: []
        )

        XCTAssertTrue(isIncluded)
    }

    // MARK: - RootPopoverView.advanceUpcomingPage 条数分页切片与游标推进

    /// advanceUpcomingPage 的便捷封装：页大小等默认取分页常量，减少用例样板。
    private func advance(
        direction: RootPopoverView.UpcomingPageDirection,
        windowItems: [CalendarItem],
        windowStart: Date,
        windowEnd: Date,
        collectedCount: Int = 0,
        loadedIdentifiers: Set<String> = [],
        pageSize: Int = 10,
        futureLimitEnd: Date? = nil,
        isResumingWindow: Bool = false
    ) -> (
        slice: RootPopoverView.UpcomingPageWindowSlice,
        nextWindowStart: Date?,
        isExhausted: Bool
    ) {
        RootPopoverView.advanceUpcomingPage(
            direction: direction,
            windowItems: windowItems,
            windowStart: windowStart,
            windowEnd: windowEnd,
            collectedCount: collectedCount,
            loadedIdentifiers: loadedIdentifiers,
            pageSize: pageSize,
            futureLimitEnd: futureLimitEnd,
            isResumingWindow: isResumingWindow
        )
    }

    /// 构造从 firstStart 起按固定间隔排列的 n 条事件夹具（标题各异，
    /// 保证未挂日历事件的后备身份互不相同）。
    private func makeSequentialEvents(
        count: Int,
        firstStart: Date,
        interval: TimeInterval = 3600,
        titlePrefix: String = "事件"
    ) -> [CalendarItem] {
        (0..<count).map { index in
            .event(makeEKEvent(
                start: firstStart.addingTimeInterval(Double(index) * interval),
                end: firstStart.addingTimeInterval(Double(index) * interval + 1800),
                title: "\(titlePrefix)\(index)"
            ))
        }
    }

    func testFuturePageTakesUpToPageSizeAndResumesSameWindow() {
        // 窗内 12 条取前 10 条凑满一页：游标停在当前窗起点（复查续接页界）
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 11, 15, 0, 0)
        let items = makeSequentialEvents(count: 12, firstStart: windowStart)

        let step = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(step.slice.takenItems.count, 10)
        XCTAssertTrue(step.slice.isPageFull)
        XCTAssertEqual(step.slice.inRangeItemCount, 12)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowStart)
    }

    func testFuturePageAdvancesToWindowEndWhenWindowSparse() {
        // 窗内条目不足一页：未凑满则游标推进到窗尾继续跨窗凑页
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 11, 15, 0, 0)
        let items = makeSequentialEvents(count: 3, firstStart: windowStart)

        let step = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(step.slice.takenItems.count, 3)
        XCTAssertFalse(step.slice.isPageFull)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowEnd)
    }

    func testFuturePageCrossesEmptyWindowWithoutExhausting() {
        // 未来方向空窗不算尽头：游标推进到窗尾继续（靠单页窗口循环上限兜底）
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 11, 15, 0, 0)

        let step = advance(
            direction: .future,
            windowItems: [],
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertTrue(step.slice.takenItems.isEmpty)
        XCTAssertEqual(step.slice.inRangeItemCount, 0)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowEnd)
    }

    func testFuturePageExhaustsAtLimitBound() {
        // 窗尾已裁剪到设置上限（windowEnd == futureLimitEnd）且未凑满：
        // 触达上限即尽头，游标置 nil
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2027, 1, 14, 10, 0)
        let items = makeSequentialEvents(count: 3, firstStart: windowStart)

        let step = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd,
            futureLimitEnd: windowEnd
        )

        XCTAssertEqual(step.slice.takenItems.count, 3)
        XCTAssertFalse(step.slice.isPageFull)
        XCTAssertTrue(step.isExhausted)
        XCTAssertNil(step.nextWindowStart)
    }

    func testFuturePageContinuationSkipsLoadedItemsAndTakesRemainder() {
        // 跨页续接：第一页取走 10 条后，第二页复查同一窗只取剩余 2 条，
        // 已加载身份不重复返回，且窗口耗尽后正常推进游标
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 11, 15, 0, 0)
        let items = makeSequentialEvents(count: 12, firstStart: windowStart)

        let firstStep = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        let loadedIdentifiers = Set(firstStep.slice.takenItems.map(\.selectionIdentifier))

        let secondStep = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd,
            loadedIdentifiers: loadedIdentifiers
        )

        XCTAssertEqual(secondStep.slice.takenItems.count, 2)
        XCTAssertFalse(secondStep.slice.isPageFull)
        XCTAssertFalse(secondStep.isExhausted)
        XCTAssertEqual(secondStep.nextWindowStart, windowEnd)
        // 取走的正是首屏未覆盖的末尾两条
        XCTAssertEqual(
            Set(secondStep.slice.takenItems.map(\.selectionIdentifier)),
            Set(items.suffix(2).map(\.selectionIdentifier))
        )
    }

    func testSameInstantGroupSplitAcrossPagesNotDuplicatedNorLost() {
        // 同刻条目跨页界：3 条同开始时间事件按页大小 2 切分，第一页取 2 条，
        // 复查后第二页恰好取走剩下 1 条，不重不漏
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 10, 20, 0, 0)
        let sameInstant = makeDate(2026, 10, 17, 9, 0)
        let items = makeSequentialEvents(
            count: 3,
            firstStart: sameInstant,
            interval: 0,
            titlePrefix: "同刻"
        )

        let firstStep = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd,
            pageSize: 2
        )
        XCTAssertEqual(firstStep.slice.takenItems.count, 2)
        XCTAssertTrue(firstStep.slice.isPageFull)

        let loadedIdentifiers = Set(firstStep.slice.takenItems.map(\.selectionIdentifier))
        let secondStep = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd,
            loadedIdentifiers: loadedIdentifiers,
            pageSize: 2
        )

        XCTAssertEqual(secondStep.slice.takenItems.count, 1)
        XCTAssertEqual(
            Set(firstStep.slice.takenItems.map(\.selectionIdentifier))
                .union(secondStep.slice.takenItems.map(\.selectionIdentifier)),
            Set(items.map(\.selectionIdentifier))
        )
        // 两页取走集合不相交（不重复）
        XCTAssertTrue(
            Set(firstStep.slice.takenItems.map(\.selectionIdentifier))
                .isDisjoint(with: Set(secondStep.slice.takenItems.map(\.selectionIdentifier)))
        )
    }

    func testPastPageTakesMostRecentItemsFirst() {
        // 过去方向取离游标最近的一批：窗内 12 条取最近的 10 条（开始时间
        // 最大者），输出按升序存放
        let windowStart = makeDate(2026, 10, 1, 0, 0)
        let windowEnd = makeDate(2026, 10, 16, 0, 0)
        let items = makeSequentialEvents(count: 12, firstStart: windowStart)

        let step = advance(
            direction: .past,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(step.slice.takenItems.count, 10)
        XCTAssertTrue(step.slice.isPageFull)
        // 输出升序：最早的取走条目是原序列第 3 条
        XCTAssertEqual(
            step.slice.takenItems.map(\.startDate),
            Array(items.suffix(10)).map(\.startDate)
        )
        XCTAssertEqual(step.nextWindowStart, windowStart)
        XCTAssertFalse(step.isExhausted)
    }

    func testPastEmptyWindowExhausts() {
        // 过去端空窗即尽头（沿用「带不回条目即历史起点」启发式）
        let windowStart = makeDate(2026, 10, 1, 0, 0)
        let windowEnd = makeDate(2026, 10, 16, 0, 0)

        let step = advance(
            direction: .past,
            windowItems: [],
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertTrue(step.slice.takenItems.isEmpty)
        XCTAssertEqual(step.slice.inRangeItemCount, 0)
        XCTAssertTrue(step.isExhausted)
        XCTAssertNil(step.nextWindowStart)
    }

    @MainActor
    func testPastWindowWithOnlyLoadedReminderAdvances() {
        // 窗内仅有已加载条目（递归提醒逐窗重复返回同一对象）：不算空窗，
        // 推进游标继续，避免误判历史尽头
        let windowStart = makeDate(2026, 10, 1, 0, 0)
        let windowEnd = makeDate(2026, 10, 16, 0, 0)
        let reminder = makeReminder(2026, 10, 8, 9, 0)
        let loadedItem = CalendarItem.reminder(reminder)

        let step = advance(
            direction: .past,
            windowItems: [loadedItem],
            windowStart: windowStart,
            windowEnd: windowEnd,
            loadedIdentifiers: [loadedItem.selectionIdentifier]
        )

        XCTAssertTrue(step.slice.takenItems.isEmpty)
        XCTAssertEqual(step.slice.inRangeItemCount, 1)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowStart)
    }

    func testPastResumeWindowWithNoNewItemsAdvances() {
        // 页满中断后的同窗复查带不回新条目：只代表窗口耗尽，不算尽头，
        // 推进游标到下一窗
        let windowStart = makeDate(2026, 10, 1, 0, 0)
        let windowEnd = makeDate(2026, 10, 16, 0, 0)

        let step = advance(
            direction: .past,
            windowItems: [],
            windowStart: windowStart,
            windowEnd: windowEnd,
            isResumingWindow: true
        )

        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowStart)
    }

    func testPastPageAdvancesAfterConsumingWindowItems() {
        // 过去窗条目全部取走仍未凑满：游标推进到窗头（即下一窗上界）
        let windowStart = makeDate(2026, 10, 1, 0, 0)
        let windowEnd = makeDate(2026, 10, 16, 0, 0)
        let items = makeSequentialEvents(count: 3, firstStart: windowStart)

        let step = advance(
            direction: .past,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        XCTAssertEqual(step.slice.takenItems.count, 3)
        XCTAssertFalse(step.slice.isPageFull)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowStart)
    }

    func testPageSizeBoundaryAlreadyFullTakesNothing() {
        // 页大小边界：本页已凑满时再喂窗结果不取任何条目，仍判页满
        let windowStart = makeDate(2026, 10, 16, 0, 0)
        let windowEnd = makeDate(2026, 11, 15, 0, 0)
        let items = makeSequentialEvents(count: 5, firstStart: windowStart)

        let step = advance(
            direction: .future,
            windowItems: items,
            windowStart: windowStart,
            windowEnd: windowEnd,
            collectedCount: 10
        )

        XCTAssertTrue(step.slice.takenItems.isEmpty)
        XCTAssertTrue(step.slice.isPageFull)
        XCTAssertFalse(step.isExhausted)
        XCTAssertEqual(step.nextWindowStart, windowStart)
    }

    // MARK: - 夹具

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ).date!
    }

    private func makeEKEvent(
        start: Date,
        end: Date,
        allDay: Bool = false,
        title: String? = nil
    ) -> EKEvent {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title ?? (allDay ? "全天事件" : "事件")
        event.startDate = start
        event.endDate = end
        // 固定事件时区，避免全天事件的日期归一化跟随本机时区漂移
        event.timeZone = TimeZone(secondsFromGMT: 0)
        event.isAllDay = allDay
        if let ekCalendar = store.defaultCalendarForNewEvents {
            event.calendar = ekCalendar
        }
        return event
    }

    private func makeEvent(start: Date, end: Date) -> CalendarItem {
        .event(makeEKEvent(start: start, end: end))
    }

    private func makeAllDayEvent(start: Date, end: Date) -> CalendarItem {
        .event(makeEKEvent(start: start, end: end, allDay: true))
    }

    private func makeReminder(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> EKReminder {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "提醒"
        reminder.dueDateComponents = DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return reminder
    }
}

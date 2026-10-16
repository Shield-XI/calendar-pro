import XCTest
import EventKit
@testable import CalendarPro

// 文件头：
// 职责：验证 UpcomingSnapshot 的按天分组纯函数（含双向窗口下的过去天组、
//       「昨天」天头与多天事件单次分组）、EventService 事件/提醒近期窗口
//       过滤（含递归展开近似），以及 RootPopoverView 未来端扩窗达界判定
//       纯函数的行为。
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

    // MARK: - RootPopoverView.isUpcomingFutureWindowExhausted 未来端达界判定

    func testFutureExhaustionFalseWhenNewItemStartsInExtensionBand() {
        // 扩窗区间 [旧端点, 新端点) 内有新条目 → 未达未来终点
        let previousFutureEnd = makeDate(2026, 11, 15, 0, 0)
        let newFutureEnd = makeDate(2026, 12, 15, 0, 0)
        let newEvent = makeEvent(
            start: makeDate(2026, 11, 20, 9, 0),
            end: makeDate(2026, 11, 20, 10, 0)
        )

        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [newEvent],
            previousFutureEnd: previousFutureEnd,
            newFutureEnd: newFutureEnd
        )

        XCTAssertFalse(isExhausted)
    }

    func testFutureExhaustionTrueWhenNoItemStartsInExtensionBand() {
        // 全部条目都开始于旧端点之前（扩窗没带新东西）→ 已达未来终点，
        // 防止 dayLimit=0 时哨兵无限循环
        let previousFutureEnd = makeDate(2026, 11, 15, 0, 0)
        let newFutureEnd = makeDate(2026, 12, 15, 0, 0)
        let oldEvent = makeEvent(
            start: makeDate(2026, 11, 10, 9, 0),
            end: makeDate(2026, 11, 10, 10, 0)
        )

        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [oldEvent],
            previousFutureEnd: previousFutureEnd,
            newFutureEnd: newFutureEnd
        )

        XCTAssertTrue(isExhausted)
    }

    func testFutureExhaustionTrueForEmptyResult() {
        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [],
            previousFutureEnd: makeDate(2026, 11, 15, 0, 0),
            newFutureEnd: makeDate(2026, 12, 15, 0, 0)
        )

        XCTAssertTrue(isExhausted)
    }

    func testFutureExhaustionTreatsStartAtPreviousEndAsNewFutureItem() {
        // 开始时间恰好等于旧端点的条目计入新扩展区间（左闭），避免误判达界
        let previousFutureEnd = makeDate(2026, 11, 15, 0, 0)
        let newFutureEnd = makeDate(2026, 12, 15, 0, 0)
        let boundaryEvent = makeEvent(
            start: previousFutureEnd,
            end: makeDate(2026, 11, 15, 10, 0)
        )

        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [boundaryEvent],
            previousFutureEnd: previousFutureEnd,
            newFutureEnd: newFutureEnd
        )

        XCTAssertFalse(isExhausted)
    }

    func testFutureExhaustionIgnoresItemAtOrBeyondNewWindowEnd() {
        // 开始时间不早于新端点的条目不计入（右开），不阻止达界判定
        let previousFutureEnd = makeDate(2026, 11, 15, 0, 0)
        let newFutureEnd = makeDate(2026, 12, 15, 0, 0)
        let atEndEvent = makeEvent(
            start: newFutureEnd,
            end: makeDate(2026, 12, 15, 10, 0)
        )
        let beyondEndEvent = makeEvent(
            start: makeDate(2026, 12, 20, 9, 0),
            end: makeDate(2026, 12, 20, 10, 0)
        )

        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [atEndEvent, beyondEndEvent],
            previousFutureEnd: previousFutureEnd,
            newFutureEnd: newFutureEnd
        )

        XCTAssertTrue(isExhausted)
    }

    @MainActor
    func testFutureExhaustionIgnoresItemWithoutStartDate() {
        // 无到期时间的提醒没有开始日期，无法落入扩展区间，不参与判定
        let reminderWithoutDueDate = EKReminder(eventStore: EKEventStore())
        reminderWithoutDueDate.title = "无到期提醒"

        let isExhausted = RootPopoverView.isUpcomingFutureWindowExhausted(
            items: [CalendarItem.reminder(reminderWithoutDueDate)],
            previousFutureEnd: makeDate(2026, 11, 15, 0, 0),
            newFutureEnd: makeDate(2026, 12, 15, 0, 0)
        )

        XCTAssertTrue(isExhausted)
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

    private func makeEKEvent(start: Date, end: Date, allDay: Bool = false) -> EKEvent {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = allDay ? "全天事件" : "事件"
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

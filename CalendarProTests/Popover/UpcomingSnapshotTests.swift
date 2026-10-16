import XCTest
import EventKit
@testable import CalendarPro

// 文件头：
// 职责：验证 UpcomingSnapshot 的按天分组纯函数，以及 EventService 提醒窗口
//       过滤（含递归展开近似）的行为。
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

    // MARK: - EventService.reminder(isDueWithin:) 窗口过滤

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

    private func makeEvent(start: Date, end: Date) -> CalendarItem {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "事件"
        event.startDate = start
        event.endDate = end
        // 固定事件时区，避免全天事件的日期归一化跟随本机时区漂移
        event.timeZone = TimeZone(secondsFromGMT: 0)
        if let ekCalendar = store.defaultCalendarForNewEvents {
            event.calendar = ekCalendar
        }
        return .event(event)
    }

    private func makeAllDayEvent(start: Date, end: Date) -> CalendarItem {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "全天事件"
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone(secondsFromGMT: 0)
        event.isAllDay = true
        if let ekCalendar = store.defaultCalendarForNewEvents {
            event.calendar = ekCalendar
        }
        return .event(event)
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

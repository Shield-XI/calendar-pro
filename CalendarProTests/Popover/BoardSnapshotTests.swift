import XCTest
import EventKit
@testable import CalendarPro

// 文件头：
// 职责：验证提醒事项看板纯函数布局——优先级映射、两种分组、组内排序、
//       时间桶边界、颜色解析（逾期双色/时间分段/无日期/已完成）与预设方案。
// 入口：xcodebuild test（CalendarProTests scheme）。
// 输入来源：测试内构造的 EKReminder（GMT 固定日期与优先级）。
// 输出：XCTest 断言结果。
// 依赖：EventKit（构造 EKReminder/EKCalendar）、BoardSnapshot 纯函数。
// 副作用：无（不读写 EventKit 真实数据库）。

final class BoardSnapshotTests: XCTestCase {
    private let calendar = BoardSnapshotTests.makeCalendar()

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// 参考当前时间：2026-10-16 12:00 GMT。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
    }

    private func makeDate(_ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeReminder(
        title: String,
        listName: String = "Inbox",
        priority: Int = 0,
        due: Date? = nil,
        includesTime: Bool = true,
        isCompleted: Bool = false
    ) -> EKReminder {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        reminder.calendar = list
        reminder.title = title
        reminder.priority = priority
        reminder.isCompleted = isCompleted

        if let due {
            var components = calendar.dateComponents([.year, .month, .day], from: due)
            if includesTime {
                components.hour = calendar.component(.hour, from: due)
                components.minute = calendar.component(.minute, from: due)
            }
            reminder.dueDateComponents = components
        }

        return reminder
    }

    private func makeSnapshot(
        _ reminders: [EKReminder],
        groupingMode: RemindersBoardGroupingMode = .list,
        colorMode: RemindersBoardColorMode = .overdue,
        colorPreferences: BoardColorPreferences = .classic,
        showCompleted: Bool = false
    ) -> BoardSnapshot {
        BoardSnapshot.make(
            reminders: reminders,
            now: now,
            calendar: calendar,
            groupingMode: groupingMode,
            colorMode: colorMode,
            colorPreferences: colorPreferences,
            showCompleted: showCompleted
        )
    }

    // MARK: - 优先级映射

    func testPriorityMappingCoversEKPriorityRanges() {
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 0), .none)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 1), .high)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 3), .high)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 4), .medium)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 6), .medium)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 7), .low)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 9), .low)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: 10), .none)
        XCTAssertEqual(ReminderBoardPriority(ekPriority: -1), .none)
    }

    // MARK: - 分组

    func testGroupingByListUsesListNameAndSortsGroupsByName() {
        let snapshot = makeSnapshot([
            makeReminder(title: "beta", listName: "Work"),
            makeReminder(title: "alpha", listName: "Home")
        ])

        XCTAssertEqual(snapshot.groups.map(\.title), ["Home", "Work"])
        XCTAssertEqual(snapshot.groups[0].rows.map(\.title), ["alpha"])
        XCTAssertEqual(snapshot.groups[1].rows.map(\.title), ["beta"])
    }

    func testGroupingByPriorityOrdersHighMediumLowNoneAndSkipsEmptyGroups() {
        let snapshot = makeSnapshot(
            [
                makeReminder(title: "none-task", priority: 0),
                makeReminder(title: "low-task", priority: 7),
                makeReminder(title: "high-task", priority: 2),
                makeReminder(title: "medium-task", priority: 5)
            ],
            groupingMode: .priority
        )

        XCTAssertEqual(snapshot.groups.map(\.title), ["高", "中", "低", "无"])
        XCTAssertEqual(snapshot.groups[0].rows.map(\.title), ["high-task"])
        XCTAssertEqual(snapshot.groups[3].rows.map(\.title), ["none-task"])

        // 只有高优先级时其余档位不产生空组。
        let single = makeSnapshot(
            [makeReminder(title: "high-task", priority: 1)],
            groupingMode: .priority
        )
        XCTAssertEqual(single.groups.count, 1)
    }

    // MARK: - 组内排序

    func testRowsSortByDueDateWithNoDateLastThenTitle() {
        let snapshot = makeSnapshot([
            makeReminder(title: "zebra", due: makeDate(10, 16, hour: 9)),
            makeReminder(title: "no-date-b", due: nil),
            makeReminder(title: "early", due: makeDate(10, 15, hour: 8)),
            makeReminder(title: "no-date-a", due: nil),
            makeReminder(title: "same-time-b", due: makeDate(10, 16, hour: 9)),
            makeReminder(title: "same-time-a", due: makeDate(10, 16, hour: 9))
        ])

        XCTAssertEqual(
            snapshot.groups[0].rows.map(\.title),
            ["early", "same-time-a", "same-time-b", "zebra", "no-date-a", "no-date-b"]
        )
    }

    // MARK: - 时间桶

    func testTimeBucketBoundaries() {
        let cases: [(due: Date?, expected: ReminderBoardTimeBucket)] = [
            (makeDate(10, 15, hour: 23, minute: 59), .past),
            (makeDate(10, 16, hour: 0, minute: 0), .today),
            (makeDate(10, 17, hour: 0, minute: 0), .thisWeek),
            (makeDate(10, 22, hour: 23, minute: 59), .thisWeek),
            (makeDate(10, 23, hour: 0, minute: 0), .later),
            (nil, .none)
        ]

        for (due, expected) in cases {
            XCTAssertEqual(
                ReminderBoardTimeBucket.resolve(dueDate: due, now: now, calendar: calendar),
                expected,
                "due \(String(describing: due)) 应解析为 \(expected)"
            )
        }
    }

    // MARK: - 颜色解析

    func testOverdueColorModeResolvesTwoColors() {
        let rows = makeSnapshot(
            [
                makeReminder(title: "overdue", due: makeDate(10, 10)),
                makeReminder(title: "today", due: makeDate(10, 16)),
                makeReminder(title: "later", due: makeDate(10, 30))
            ]
        ).groups[0].rows

        let colorByTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.colorHex) })
        XCTAssertEqual(colorByTitle["overdue"], BoardColorPreferences.classic.overdue)
        XCTAssertEqual(colorByTitle["today"], BoardColorPreferences.classic.notOverdue)
        XCTAssertEqual(colorByTitle["later"], BoardColorPreferences.classic.notOverdue)
    }

    func testTimeBucketColorModeMapsBuckets() {
        let rows = makeSnapshot(
            [
                makeReminder(title: "past", due: makeDate(10, 10)),
                makeReminder(title: "today", due: makeDate(10, 16)),
                makeReminder(title: "this-week", due: makeDate(10, 20)),
                makeReminder(title: "later", due: makeDate(11, 1))
            ],
            colorMode: .timeBucket
        ).groups[0].rows

        let colorByTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.colorHex) })
        XCTAssertEqual(colorByTitle["past"], BoardColorPreferences.classic.past)
        XCTAssertEqual(colorByTitle["today"], BoardColorPreferences.classic.today)
        XCTAssertEqual(colorByTitle["this-week"], BoardColorPreferences.classic.thisWeek)
        XCTAssertEqual(colorByTitle["later"], BoardColorPreferences.classic.later)
    }

    func testNoDateRowAlwaysUsesNoDateColor() {
        for colorMode in RemindersBoardColorMode.allCases {
            let rows = makeSnapshot(
                [makeReminder(title: "someday", due: nil)],
                colorMode: colorMode
            ).groups[0].rows

            XCTAssertEqual(rows.first?.colorHex, BoardColorPreferences.classic.noDate)
            XCTAssertNil(rows.first?.dueText)
        }
    }

    func testCompletedRowsUseCompletedColorAndFilterByShowCompleted() {
        let reminders = [
            makeReminder(title: "done", due: makeDate(10, 10), isCompleted: true),
            makeReminder(title: "done-no-date", due: nil, isCompleted: true),
            makeReminder(title: "todo", due: makeDate(10, 17))
        ]

        for colorMode in RemindersBoardColorMode.allCases {
            let visible = makeSnapshot(reminders, colorMode: colorMode, showCompleted: true)
                .groups[0].rows
            XCTAssertEqual(visible.count, 3)

            // 已完成恒用 completed 色：任务行标题/勾选图标/到期标签共用该值着色。
            let done = visible.first { $0.title == "done" }
            XCTAssertEqual(done?.colorHex, BoardColorPreferences.classic.completed)
            XCTAssertTrue(done?.isCompleted ?? false)

            let doneNoDate = visible.first { $0.title == "done-no-date" }
            XCTAssertEqual(doneNoDate?.colorHex, BoardColorPreferences.classic.completed)
        }

        // completed 优先于无日期色：用两者取值不同的调色板验证已完成且无日期不给 noDate 色。
        var distinctPalette = BoardColorPreferences.classic
        distinctPalette.noDate = "#00FF00"

        let withDistinctNoDate = makeSnapshot(
            [makeReminder(title: "done-no-date", due: nil, isCompleted: true)],
            colorPreferences: distinctPalette,
            showCompleted: true
        ).groups[0].rows

        XCTAssertEqual(withDistinctNoDate.first?.colorHex, distinctPalette.completed)

        let hidden = makeSnapshot(reminders, showCompleted: false)
        XCTAssertEqual(hidden.groups[0].rows.map(\.title), ["todo"])
        XCTAssertEqual(hidden.incompleteCount, 1)
    }

    func testIncompleteCountCountsOnlyIncompleteRows() {
        let snapshot = makeSnapshot(
            [
                makeReminder(title: "a", isCompleted: true),
                makeReminder(title: "b"),
                makeReminder(title: "c")
            ],
            showCompleted: true
        )

        XCTAssertEqual(snapshot.groups[0].rows.count, 3)
        XCTAssertEqual(snapshot.incompleteCount, 2)
    }

    // MARK: - 预设方案

    func testPresetPalettesAreCompleteAndCustomHasNoPalette() {
        for preset in [BoardColorPreset.classic, .warm, .cool, .highContrast] {
            guard let palette = preset.colorPreferences else {
                XCTFail("\(preset) 应提供完整配色")
                continue
            }

            for key in BoardColorKey.allCases {
                XCTAssertTrue(palette.colorHex(for: key).hasPrefix("#"), "\(preset).\(key) 应为 hex")
            }
        }

        XCTAssertNil(BoardColorPreset.custom.colorPreferences)
    }

    func testPresetPalettesAreDistinct() {
        let palettes = [BoardColorPreset.classic, .warm, .cool, .highContrast]
            .compactMap(\.colorPreferences)
        XCTAssertEqual(Set(palettes).count, 4, "各预设配色应互不相同")
    }
}

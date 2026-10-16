import SwiftUI
import XCTest
@testable import CalendarPro

// 文件头：
// 职责：验证弹层尺寸约束纯函数——按钮下方可用高度计算、内容尺寸 clamp、
//       异常布局的保底高度，以及宿主控制器对 preferredContentSize 的高度钳制。
// 入口：xcodebuild test（CalendarProTests scheme）。
// 输入来源：测试内构造的屏幕 frame（状态栏按钮屏幕坐标与 visibleFrame）。
// 输出：XCTest 断言结果。
// 依赖：PopoverSizing 纯函数、PopoverSizingHostingController、SwiftUI。
// 副作用：无（不创建真实弹层窗口，不依赖显示器布局）。

@MainActor
final class PopoverSizingTests: XCTestCase {
    // 典型菜单栏场景：屏幕 1440x900、菜单栏 25pt，状态栏按钮底缘 y=850。
    private let buttonFrameInScreen = NSRect(x: 1200, y: 850, width: 44, height: 25)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    func testAvailableHeightUsesSpaceBelowAnchorButton() {
        let height = PopoverSizing.availableHeight(
            anchorButtonFrameInScreen: buttonFrameInScreen,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(height, 838)
    }

    func testClampedContentSizeKeepsFittingHeightWhenContentFits() {
        let size = PopoverSizing.clampedContentSize(
            fittingSize: NSSize(width: 340, height: 600),
            anchorButtonFrameInScreen: buttonFrameInScreen,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(size, NSSize(width: 340, height: 600))
    }

    func testClampedContentSizeLimitsHeightToAvailableSpace() {
        let size = PopoverSizing.clampedContentSize(
            fittingSize: NSSize(width: 340, height: 1600),
            anchorButtonFrameInScreen: buttonFrameInScreen,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(size, NSSize(width: 340, height: 838))
    }

    func testAvailableHeightFloorsAtMinimumForDegenerateLayouts() {
        let height = PopoverSizing.availableHeight(
            anchorButtonFrameInScreen: NSRect(x: 1200, y: 5, width: 44, height: 25),
            visibleFrame: NSRect(x: 0, y: 100, width: 1440, height: 875)
        )

        XCTAssertEqual(height, PopoverSizing.minimumHeight)
    }

    func testHostingControllerPassesThroughPreferredContentSizeWithoutLimit() {
        let controller = PopoverSizingHostingController(rootView: AnyView(EmptyView()))
        controller.preferredContentSize = NSSize(width: 340, height: 1200)

        XCTAssertEqual(controller.preferredContentSize, NSSize(width: 340, height: 1200))
    }

    func testHostingControllerClampsPreferredContentSizeHeight() {
        let controller = PopoverSizingHostingController(rootView: AnyView(EmptyView()))
        controller.maximumContentHeight = 838
        controller.preferredContentSize = NSSize(width: 340, height: 1200)

        XCTAssertEqual(controller.preferredContentSize, NSSize(width: 340, height: 838))
    }
}

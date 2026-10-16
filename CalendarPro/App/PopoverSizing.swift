import AppKit
import SwiftUI

// 文件头：
// 职责：菜单栏弹层的尺寸约束工具——依据状态栏按钮下方的屏幕可用空间
//       计算弹层高度上限，并提供带高度上限的 SwiftUI 宿主控制器，
//       防止弹层随内容增长被顶出屏幕上缘（顶部圆角被裁切的根因）。
// 入口：PopoverSizing.clampedContentSize /
//       PopoverSizing.availableHeight（纯函数，PopoverController 显示前调用）；
//       PopoverSizingHostingController（PopoverController 的内容宿主）。
// 输入来源：弹层内容理想尺寸（popover.contentSize）、状态栏按钮屏幕坐标
//       frame（window.convertToScreen）、所在屏幕 visibleFrame。
// 输出：clamp 后的弹层尺寸（NSSize）与最大内容高度。
// 依赖：AppKit、SwiftUI。
// 副作用：纯函数无副作用；宿主控制器仅覆写 preferredContentSize 读取路径，
//       不改变 SwiftUI 内容本身。

enum PopoverSizing {
    /// 弹层与状态栏按钮之间保留的安全间距（含 NSPopover 箭头间隙与屏幕上缘余量）。
    static let verticalSpacingMargin: CGFloat = 12

    /// 可用高度异常偏小时的保底弹层高度，取值与 EventDetailWindowSizing.minHeight 对齐。
    static let minimumHeight: CGFloat = 280

    /// 状态栏按钮下方、屏幕可见区域内的最大可用弹层高度。
    /// 按钮底缘低于可见区（如外接屏布局异常）时回退保底高度，避免得到 0 或负值。
    /// - Parameters:
    ///   - anchorButtonFrameInScreen: 状态栏按钮在屏幕坐标系下的 frame
    ///     （window.convertToScreen 换算，原点左下、y 向上）。
    ///   - visibleFrame: 按钮所在屏幕的可见区域（不含菜单栏与 Dock）。
    /// - Returns: 可用高度（CGFloat），已扣除安全间距并施加保底下限。
    static func availableHeight(
        anchorButtonFrameInScreen: NSRect,
        visibleFrame: NSRect
    ) -> CGFloat {
        let spaceBelowButton = anchorButtonFrameInScreen.minY - visibleFrame.minY
        return max(spaceBelowButton - verticalSpacingMargin, minimumHeight)
    }

    /// 依据内容理想尺寸与屏幕可用空间计算弹层尺寸：内容放得下时保持理想高度，
    /// 放不下时取按钮下方可用高度，超出部分交由弹层内 ScrollView 滚动。
    /// - Parameters:
    ///   - fittingSize: 弹层内容的理想尺寸（SwiftUI fittingSize）。
    ///   - anchorButtonFrameInScreen: 状态栏按钮在屏幕坐标系下的 frame。
    ///   - visibleFrame: 按钮所在屏幕的可见区域。
    /// - Returns: clamp 后的弹层尺寸（NSSize），宽度保持理想宽度。
    static func clampedContentSize(
        fittingSize: NSSize,
        anchorButtonFrameInScreen: NSRect,
        visibleFrame: NSRect
    ) -> NSSize {
        let maximumHeight = availableHeight(
            anchorButtonFrameInScreen: anchorButtonFrameInScreen,
            visibleFrame: visibleFrame
        )
        return NSSize(
            width: fittingSize.width,
            height: min(fittingSize.height, maximumHeight)
        )
    }
}

/// 带高度上限的 SwiftUI 宿主控制器。
/// sizingOptions = .preferredContentSize 会让弹层在内容变化（如展开看板分节）
/// 时持续跟随内容理想尺寸 resize；此处覆写 preferredContentSize 读取路径，
/// 把高度钳制在 maximumContentHeight 内，弹层窗口因此不会再被撑出屏幕。
/// 内部写入仍经 super 存储，未设上限（首次显示前）行为与原生一致。
final class PopoverSizingHostingController: NSHostingController<AnyView> {
    /// 弹层内容允许的最大高度；nil 表示暂不限制（首次显示前的初始状态）。
    /// 来源：PopoverSizing.availableHeight 在每次 showPopover 前计算写入。
    var maximumContentHeight: CGFloat?

    override var preferredContentSize: NSSize {
        get {
            let size = super.preferredContentSize
            guard let maximumContentHeight else { return size }
            return NSSize(
                width: size.width,
                height: min(size.height, maximumContentHeight)
            )
        }
        set { super.preferredContentSize = newValue }
    }
}

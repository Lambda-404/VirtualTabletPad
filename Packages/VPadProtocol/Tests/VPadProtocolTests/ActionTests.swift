import XCTest
@testable import VPadProtocol

final class ActionTests: XCTestCase {

    func testActionEnumVariantsAndCodable() throws {
        let keyAction = Action.key(KeyCombo(keyCode: 55, modifiers: 0x0001))
        let sysAction = Action.systemAction(.missionControl)
        let macroAction = Action.macro([
            .keyDown(55, modifiers: 0),
            .delayMs(25),
            .keyDown(6, modifiers: 55),
            .keyUp(6),
            .keyUp(55)
        ])
        let toolAction = Action.toggleTool("eraser")

        let actions = [keyAction, sysAction, macroAction, toolAction]
        let data = try JSONEncoder().encode(actions)
        let decoded = try JSONDecoder().decode([Action].self, from: data)

        XCTAssertEqual(actions, decoded)
    }

    func testPencilGestureBindings() throws {
        var bindings = PencilGestureBindings()
        XCTAssertEqual(bindings.doubleTapAction, .toggleTool("eraser"))

        bindings.squeezeAction = .systemAction(.appExpose)
        bindings.doubleTapAction = .key(KeyCombo(keyCode: 14)) // 'E' key

        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(PencilGestureBindings.self, from: data)

        XCTAssertEqual(bindings, decoded)
    }

    func testActionTitleFormatting() {
        XCTAssertEqual(Action.key(KeyCombo(keyCode: 49)).title, "Key (49)")
        XCTAssertEqual(Action.systemAction(.playPause).title, "Play / Pause")
        XCTAssertEqual(Action.toggleTool("brush").title, "Tool: Brush")
        XCTAssertEqual(Action.macro([.delayMs(10)]).title, "Macro (1 steps)")
    }

    @MainActor
    final class MockActionDispatcher: ActionDispatcher {
        var shortcuts: [(UInt16, UInt16)] = []
        var keyPresses: [(UInt16, Phase, UInt16)] = []
        var systemActions: [SystemAction] = []
        var tools: [String] = []

        func sendShortcut(keyCode: UInt16, modifiers: UInt16) {
            shortcuts.append((keyCode, modifiers))
        }

        func sendKeyboardPress(keyCode: UInt16, phase: Phase, modifiers: UInt16) {
            keyPresses.append((keyCode, phase, modifiers))
        }

        func sendSystemAction(_ action: SystemAction) {
            systemActions.append(action)
        }

        func selectTool(_ tool: String) {
            tools.append(tool)
        }
    }

    @MainActor
    func testActionRunnerExecution() {
        let mock = MockActionDispatcher()
        ActionRunner.execute(.key(KeyCombo(keyCode: 53, modifiers: 2)), via: mock)
        XCTAssertEqual(mock.shortcuts.count, 1)
        XCTAssertEqual(mock.shortcuts[0].0, 53)
        XCTAssertEqual(mock.shortcuts[0].1, 2)

        ActionRunner.execute(.systemAction(.mute), via: mock)
        XCTAssertEqual(mock.systemActions, [.mute])

        ActionRunner.execute(.toggleTool("eraser"), via: mock)
        XCTAssertEqual(mock.tools, ["eraser"])
    }
}

import AppKit
import SwiftUI

struct FocusTimerView: View {
    @ObservedObject var store: FocusTimerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        switch store.phase {
        case .idle: return "设置时长，到点提醒"
        case .running: return "正在倒计时"
        case .paused: return "已暂停"
        case .finished: return "时间到"
        }
    }

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 4)
                Circle().trim(from: 0, to: store.phase == .idle ? 1 : 1 - store.progress)
                    .stroke(store.phase == .finished ? Color.mint : .orange,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: store.progress)
                VStack(spacing: 8) {
                    Image(systemName: store.phase == .finished ? "bell.fill" : "alarm")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(.orange)
                    Text(store.formattedRemaining)
                        .font(.system(size: 31, weight: .medium, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.65).lineLimit(1)
                        .contentTransition(.numericText(countsDown: true))
                    Text(store.phase == .finished ? "时间到" : store.phase == .paused ? "已暂停" : "剩余时间")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }.padding(12)
            }.frame(width: 158, height: 158)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("倒计时").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text(status).font(.system(size: 11)).foregroundStyle(store.phase == .finished ? Color.mint : .white.opacity(0.6))
                }
                HStack(spacing: 10) {
                    durationPicker("小时", unit: 3600, range: 0...23)
                    durationPicker("分钟", unit: 60, range: 0...59)
                    durationPicker("秒", unit: 1, range: 0...59)
                    Spacer(minLength: 8)
                    ForEach([1, 5, 10], id: \.self) { minutes in
                        Button("\(minutes)分钟") { store.configure(minutes: minutes) }
                            .buttonStyle(ProductivityPillStyle(selected: Int(store.duration) == minutes * 60))
                            .disabled(!store.canConfigure)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        switch store.phase {
                        case .idle, .finished: store.start()
                        case .running: store.pause()
                        case .paused: store.resume()
                        }
                    } label: {
                        Label(store.phase == .running ? "暂停" : store.phase == .paused ? "继续" : store.phase == .finished ? "再来一次" : "开始",
                              systemImage: store.phase == .running ? "pause.fill" : "play.fill")
                            .frame(minWidth: 90)
                    }.buttonStyle(ProductivityPillStyle(selected: true, prominent: true))
                    Button { store.reset() } label: { Label("重置", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(ProductivityPillStyle())
                    Spacer()
                }
                Text(store.lastError ?? "到点播放提示音。收起灵动岛后继续计时。")
                    .font(.system(size: 10)).foregroundStyle(store.lastError == nil ? Color.white.opacity(0.5) : .orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity).frame(height: 174)
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .onExitCommand { NotificationCenter.default.post(name: .lyriamCollapseIsland, object: nil) }
    }

    private func durationPicker(_ title: String, unit: Int, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            Picker(title, selection: Binding(get: {
                let value = Int(store.duration)
                return unit == 3600 ? value / 3600 : unit == 60 ? (value / 60) % 60 : value % 60
            }, set: { selected in
                let value = Int(store.duration)
                let current = unit == 3600 ? value / 3600 : unit == 60 ? (value / 60) % 60 : value % 60
                store.configure(seconds: max(1, value + (selected - current) * unit))
            })) {
                ForEach(Array(range), id: \.self) { number in Text(String(format: "%02d", number)).tag(number) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 66)
            .disabled(!store.canConfigure).accessibilityLabel(title)
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

struct QuickNotesView: View {
    @ObservedObject var store: NotesStore
    @State private var draftTodo = ""
    @FocusState private var todoFocused: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("便签", systemImage: "note.text")
                        Spacer()
                        Text(store.lastError != nil ? "未保存" : store.hasUnsavedChanges ? "保存中…" : "已保存在此 Mac")
                            .font(.system(size: 9)).foregroundStyle(store.lastError == nil ? Color.white.opacity(0.55) : .orange)
                    }.font(.system(size: 11, weight: .semibold))
                    ZStack(alignment: .topLeading) {
                        if store.note.isEmpty {
                            Text("随手记点什么…")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 6).padding(.vertical, 9).allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(get: { store.note }, set: store.updateNote))
                            .font(.system(size: 12)).foregroundStyle(.white)
                            .scrollContentBackground(.hidden).padding(.vertical, 4)
                            .accessibilityLabel("快速便签")
                    }
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("待办", systemImage: "checklist")
                        Text("\(store.todos.filter { !$0.isComplete }.count)")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        if store.deletedTodo != nil {
                            Button("撤销删除", action: store.undoDelete)
                                .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.mint)
                        }
                    }.font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 7) {
                        TextField("添加待办，按回车", text: $draftTodo)
                            .textFieldStyle(.plain).font(.system(size: 11))
                            .focused($todoFocused).onSubmit(addTodo)
                        Button(action: addTodo) { Image(systemName: "plus.circle.fill").font(.system(size: 15)) }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                            .disabled(draftTodo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("添加待办")
                    }.padding(8).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    if store.todos.isEmpty {
                        Text("把接下来要做的事放在这里。")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(store.todos) { todo in
                                    HStack(alignment: .center, spacing: 7) {
                                        Button { store.toggleTodo(todo) } label: {
                                            Image(systemName: todo.isComplete ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 14)).foregroundStyle(todo.isComplete ? Color.mint : .white.opacity(0.65))
                                        }.buttonStyle(.plain).accessibilityLabel(todo.isComplete ? "标记为未完成" : "完成待办")
                                        Text(todo.text).font(.system(size: 11)).lineLimit(2)
                                            .strikethrough(todo.isComplete).foregroundStyle(.white.opacity(todo.isComplete ? 0.45 : 0.9))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button { store.deleteTodo(todo) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4)).help("删除待办")
                                    }.padding(.horizontal, 7).padding(.vertical, 6)
                                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = store.lastError {
                HStack(spacing: 6) {
                    Text(error).font(.system(size: 9)).lineLimit(1)
                    Spacer(minLength: 0)
                    if store.canRetrySaving {
                        Button("重试", action: store.flush).font(.system(size: 9)).buttonStyle(.plain)
                    }
                }.foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 4).padding(.top, 3)
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .onDisappear { store.flush() }
        .onExitCommand { NotificationCenter.default.post(name: .lyriamCollapseIsland, object: nil) }
    }

    private func addTodo() {
        if store.addTodo(draftTodo) { draftTodo = ""; todoFocused = true }
    }
}

private struct ProductivityPillStyle: ButtonStyle {
    var selected = false
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : selected ? Color.orange : .white.opacity(0.8))
            .padding(.horizontal, prominent ? 15 : 11).padding(.vertical, 8)
            .background(prominent ? Color.orange : selected ? Color.orange.opacity(0.16) : .white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

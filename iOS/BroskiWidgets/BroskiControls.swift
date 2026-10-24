import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action Button controls: one tap and Broski is listening.
@main
struct BroskiWidgets: WidgetBundle {
    var body: some Widget {
        TalkControl()
        NoteControl()
    }
}

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "broski.control.talk") {
            ControlWidgetButton(action: TalkToBroskiIntent()) {
                Label("Talk to Broski", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to Broski")
        .description("Opens Broski listening.")
    }
}

struct NoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "broski.control.note") {
            ControlWidgetButton(action: NewBroskiNoteIntent()) {
                Label("New Broski note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Broski note")
        .description("Opens Broski ready to type.")
    }
}

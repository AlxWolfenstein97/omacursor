import QtQuick
import Quickshell
import Quickshell.Io

// OmaCursor service plugin.
//
// Cursor recoloring lives in bin/omacursor; the theme-set hook keeps slots in
// step. This service only re-runs install.sh once at shell start (menu/hook/
// packages). No probe timer — the hook already covers theme switches, and a
// second sync path made boots/flips feel heavier than they needed to.
Item {
    id: root
    visible: false

    property var shell: null
    property var manifest: null
    property string lastError: ""

    readonly property string pluginDir: {
        if (manifest && manifest.__sourceDir)
            return String(manifest.__sourceDir)
        var here = String(Qt.resolvedUrl("."))
        if (here.startsWith("file://"))
            here = here.substring(7)
        if (here.endsWith("/"))
            here = here.slice(0, -1)
        return decodeURIComponent(here)
    }

    Process {
        id: installer
        command: ["bash", root.pluginDir + "/install.sh", "--quiet"]
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var message = String(text || "").trim()
                if (message.length > 0)
                    root.lastError = message.length > 400 ? message.slice(-400) : message
            }
        }
        onExited: function (exitCode) {
            if (exitCode === 0)
                return
            console.warn("omacursor: installer exited " + exitCode
                         + (root.lastError.length > 0 ? ": " + root.lastError : ""))
        }
    }

    Timer {
        interval: 2500
        running: true
        repeat: false
        onTriggered: {
            if (!installer.running) {
                root.lastError = ""
                installer.running = true
            }
        }
    }
}

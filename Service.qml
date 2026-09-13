import QtQuick
import Quickshell
import Quickshell.Io

// OmaCursor service plugin.
//
// Cursor recoloring lives in bin/omacursor; the theme-set hook keeps the
// managed cursor slots in step with Omarchy. This service re-runs the
// installer at shell start (menu/hook) and is the safety net if a switch
// somehow skips the hook — same idea as Chroma.
Item {
    id: root
    visible: false

    property var shell: null
    property var manifest: null
    property string lastError: ""
    property string lastSeenStamp: ""
    property string lastAppliedStamp: ""

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string themeDir: home + "/.local/state/omarchy/current/theme"
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

    // Safety net: if theme.name/colors.toml change without the hook firing,
    // re-sync within a few seconds.
    Process {
        id: probeProcess
        running: false
        command: ["sh", "-c",
            'p=$(readlink -f -- "$1") || exit 0; printf "%s %s\\n" "$p" "$(stat -c %Y -- "$p/colors.toml" 2>/dev/null)"',
            "-", root.themeDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.onProbe(text.trim())
        }
    }

    Process {
        id: syncProcess
        running: false
        command: [root.pluginDir + "/bin/omacursor-sync", "--quiet"]
        onExited: function (exitCode) {
            if (exitCode === 0)
                root.lastAppliedStamp = root.lastSeenStamp
        }
    }

    Timer {
        interval: 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!probeProcess.running)
                probeProcess.running = true
        }
    }

    function onProbe(stamp) {
        if (stamp === "")
            return
        var first = lastSeenStamp === ""
        lastSeenStamp = stamp
        if (syncProcess.running)
            return
        if (stamp === lastAppliedStamp)
            return
        // Skip the very first probe right after installer; install already synced.
        if (first) {
            lastAppliedStamp = stamp
            return
        }
        syncProcess.running = true
    }
}

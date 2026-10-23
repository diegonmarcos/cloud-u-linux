/*
 * "Available data" page: every field the running daemon is publishing right
 * now, with its current value.
 *
 * Read from the live snapshot rather than from a hardcoded list, because a
 * hardcoded list is a second source of truth that goes stale the moment
 * watchdog.rs grows or drops a field — which it has done repeatedly (psi,
 * guard voters, proc_table, the per-process averages). If it is in the file,
 * it is on this page; if it is not, the page says so instead of lying.
 *
 * This is a reference page, not a settings page: nothing here is editable.
 * It exists so "what can this widget actually show me" has an answer inside
 * the widget rather than requiring jq against /run/user/<uid>.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property var snap: ({})
    property bool loaded: false
    property string snapPath: "/run/user/" + plasmoid.configuration.uid + "/my-konsole-watchdog.json"

    function shortValue(v) {
        if (v === null || v === undefined) return "null";
        if (Array.isArray(v)) {
            if (!v.length) return "[] (empty)";
            if (typeof v[0] === "object") return "[" + v.length + " x object] keys: " + Object.keys(v[0]).join(", ");
            return "[" + v.length + "] " + v.slice(0, 8).join(", ") + (v.length > 8 ? " …" : "");
        }
        if (typeof v === "object") {
            return Object.keys(v).map(function (k) {
                var iv = v[k];
                return k + "=" + (typeof iv === "object" && iv !== null ? "{…}" : iv);
            }).join("  ");
        }
        return String(v);
    }

    function reload() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            try { page.snap = JSON.parse(xhr.responseText); page.loaded = true; }
            catch (e) { page.snap = {}; page.loaded = false; }
            page.rebuild();
        };
        xhr.open("GET", "file://" + page.snapPath);
        xhr.send();
    }

    function rebuild() {
        fieldModel.clear();
        var keys = Object.keys(page.snap).sort();
        for (var i = 0; i < keys.length; i++) {
            fieldModel.append({ field: keys[i], value: page.shortValue(page.snap[keys[i]]) });
        }
    }

    ListModel { id: fieldModel }
    Component.onCompleted: page.reload()

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            QQC2.Label {
                Layout.fillWidth: true
                text: page.loaded
                    ? fieldModel.count + " fields published by the daemon"
                    : "No readable snapshot at " + page.snapPath
                wrapMode: Text.WordWrap
            }
            QQC2.Button {
                text: "Refresh"
                icon.name: "view-refresh"
                onClicked: page.reload()
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            text: page.snapPath
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            elide: Text.ElideMiddle
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Kirigami.Units.gridUnit * 18
            clip: true

            ListView {
                model: fieldModel
                spacing: 1
                delegate: Rectangle {
                    width: ListView.view.width
                    height: row.implicitHeight + Kirigami.Units.smallSpacing
                    color: index % 2 ? "transparent" : Kirigami.Theme.alternateBackgroundColor
                    RowLayout {
                        id: row
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing / 2
                        spacing: Kirigami.Units.largeSpacing
                        QQC2.Label {
                            text: model.field
                            font.family: "monospace"
                            font.bold: true
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                        }
                        QQC2.Label {
                            text: model.value
                            font.family: "monospace"
                            Layout.fillWidth: true
                            wrapMode: Text.WrapAnywhere
                            opacity: 0.85
                        }
                    }
                }
            }
        }
    }
}

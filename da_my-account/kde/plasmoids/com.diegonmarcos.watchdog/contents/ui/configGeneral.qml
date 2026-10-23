/*
 * General page of the Watchdog config dialog.
 *
 * The three things an instance actually has: which cluster it renders, which
 * uid's snapshot it reads, and (proctable only) which averaging window the
 * process table shows.
 *
 * The cluster list is NOT hardcoded here. It is read from the same
 * contents/data/clusters.json main.qml renders from, so adding a mode there
 * makes it selectable here with no edit to this file — the whole point of
 * that file being data.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_mode: modeBox.currentValue
    property alias cfg_uid: uidBox.value
    property alias cfg_ptWindow: ptWindowBox.currentValue

    // Same synchronous read main.qml does at startup: a small static file
    // shipped inside the plasmoid, so there is no reason to make the dialog
    // race an async load.
    property var clusterDefs: ({})
    property var modeList: []

    Component.onCompleted: {
        var xhr = new XMLHttpRequest();
        try {
            xhr.open("GET", Qt.resolvedUrl("../data/clusters.json"), false);
            xhr.send();
            page.clusterDefs = JSON.parse(xhr.responseText);
        } catch (e) {
            page.clusterDefs = {};
        }
        var list = [];
        for (var k in page.clusterDefs) {
            if (k === "_comment") continue;
            list.push({ key: k, label: (page.clusterDefs[k].title || k) + "  (" + k + ")" });
        }
        page.modeList = list;
        // currentIndex has to be set after the model exists, or the box shows
        // the first entry while the config still holds something else.
        for (var i = 0; i < list.length; i++) {
            if (list[i].key === plasmoid.configuration.mode) { modeBox.currentIndex = i; break; }
        }
    }

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: modeBox
            Kirigami.FormData.label: "Cluster:"
            model: page.modeList
            textRole: "label"
            valueRole: "key"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        }

        QQC2.Label {
            Kirigami.FormData.label: "Shows:"
            text: {
                var c = page.clusterDefs[modeBox.currentValue];
                if (!c || !c.items) return "—";
                return c.items.map(function (i) { return i.kind + " " + i.metric; }).join(", ");
            }
            wrapMode: Text.WordWrap
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            id: ptWindowBox
            Kirigami.FormData.label: "Process table shows:"
            enabled: modeBox.currentValue === "proctable"
            model: [
                { key: "live", label: "live (current tick)" },
                { key: "1m",   label: "1 minute average" },
                { key: "5m",   label: "5 minute average" },
                { key: "15m",  label: "15 minute average" }
            ]
            textRole: "label"
            valueRole: "key"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 22
            Component.onCompleted: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].key === plasmoid.configuration.ptWindow) { currentIndex = i; break; }
                }
            }
        }

        QQC2.Label {
            text: "Averages are computed per process by the my-konsole tray daemon and published with each snapshot. They need the daemon build that emits them; without it every window falls back to live values."
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: uidBox
            Kirigami.FormData.label: "Snapshot uid:"
            from: 0
            to: 65535
            editable: true
        }

        QQC2.Label {
            text: "The snapshot lives in /run/user/<uid>/my-konsole-watchdog.json and QML has no getenv, so the uid is declared rather than discovered."
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }
    }
}

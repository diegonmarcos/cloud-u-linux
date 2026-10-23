/*
 * Config dialog registration. Without this file the widget has NO
 * "Configure Watchdog…" entry in its right-click menu at all — Plasma only
 * offers the action when a plasmoid ships a ConfigModel, which is why the
 * only way to change `mode` used to be editing appletsrc or redeploying the
 * panel from panels.json.
 */
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "General"
        icon: "configure"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: "Available data"
        icon: "view-list-details"
        source: "configData.qml"
    }
}

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami 2.20 as Kirigami
import org.kde.notification 1.0

PlasmoidItem {
    id: root

    readonly property string endpoint: "https://www.poe.pl.ua/customs/dynamicgpv-info.php"
    property var schedules: []
    property string errorText: ""
    property string lastUpdated: ""
    property bool loading: false
    property int clockTick: 0
    property string lastAlertKey: ""

    Plasmoid.icon: "view-calendar-day"
    activationTogglesExpanded: true

    function stripTags(value) {
        return value.replace(/<[^>]*>/g, "").replace(/&nbsp;|&#160;/g, " ").replace(/&amp;/g, "&").trim()
    }

    function dateFromText(value) {
        var months = { "січня": 0, "лютого": 1, "березня": 2, "квітня": 3, "травня": 4, "червня": 5, "липня": 6, "серпня": 7, "вересня": 8, "жовтня": 9, "листопада": 10, "грудня": 11 }
        var match = value.match(/(\d{1,2})\s+(січня|лютого|березня|квітня|травня|червня|липня|серпня|вересня|жовтня|листопада|грудня)\s+(\d{4})/i)
        return match ? new Date(Number(match[3]), months[match[2].toLowerCase()], Number(match[1])) : new Date()
    }

    function lastDateBefore(value) {
        var expression = /(\d{1,2}\s+(?:січня|лютого|березня|квітня|травня|червня|липня|серпня|вересня|жовтня|листопада|грудня)\s+\d{4})/gi
        var match
        var last = ""
        while ((match = expression.exec(value)) !== null)
            last = match[1]
        return dateFromText(last)
    }

    function timeLabel(index) {
        var minutes = index * 30
        return ("0" + Math.floor(minutes / 60)).slice(-2) + ":" + (minutes % 60 ? "30" : "00")
    }

    function parseTable(tableHtml, prefix) {
        var date = lastDateBefore(prefix)
        var rows = []
        var currentQueue = ""
        var rowMatches = tableHtml.match(/<tr\b[\s\S]*?<\/tr>/gi) || []

        rowMatches.forEach(function(rowHtml) {
            var cells = rowHtml.match(/<td\b[\s\S]*?<\/td>/gi) || []
            if (cells.length < 3)
                return
            var hasQueueCell = /turnoff-scheduleui-table-queue/i.test(cells[0])
            if (hasQueueCell)
                currentQueue = stripTags(cells[0]).replace(/\s*черга\s*/i, "")
            var subqueue = stripTags(cells[hasQueueCell ? 1 : 0])
            var scheduleCells = cells.slice(hasQueueCell ? 2 : 1)
            if (!currentQueue || !subqueue || scheduleCells.length < 2)
                return

            var states = scheduleCells.map(function(cell) {
                var classes = (cell.match(/class=["']([^"']*)["']/i) || ["", ""])[1]
                if (/\blight_2\b/.test(classes)) return "off"
                if (/\blight_3\b/.test(classes)) return "possible"
                return "on"
            })
            var intervals = []
            var state = states[0]
            var start = 0
            for (var i = 1; i <= states.length; i++) {
                if (i === states.length || states[i] !== state) {
                    intervals.push({ state: state, start: timeLabel(start), end: i === 48 ? "00:00" : timeLabel(i) })
                    state = states[i]
                    start = i
                }
            }
            rows.push({ queue: currentQueue + "." + subqueue, date: date, dateText: date.toLocaleDateString(Qt.locale().name), intervals: intervals })
        })
        return rows
    }

    function parseResponse(html) {
        var result = []
        var tables = html.match(/<table\b[^>]*turnoff-scheduleui-table[^>]*>[\s\S]*?<\/table>/gi) || []
        var cursor = 0
        tables.forEach(function(table) {
            var position = html.indexOf(table, cursor)
            result = result.concat(parseTable(table, html.slice(0, position)))
            cursor = position + table.length
        })
        return result
    }

    function selectedQueues() {
        return plasmoid.configuration.selectedQueues.split(",").filter(function(queue) { return queue.length > 0 })
    }

    function visibleSchedules() {
        var selected = selectedQueues()
        return schedules.filter(function(item) { return selected.indexOf(item.queue) !== -1 })
    }

    function updateConfiguration(parsed) {
        var available = []
        parsed.forEach(function(item) { if (available.indexOf(item.queue) === -1) available.push(item.queue) })
        var selected = selectedQueues().filter(function(queue) { return available.indexOf(queue) !== -1 })
        if (!selected.length)
            selected = available.slice(0, 1)
        plasmoid.configuration.selectedQueues = selected.join(",")
        if (selected.indexOf(plasmoid.configuration.priorityQueue) === -1)
            plasmoid.configuration.priorityQueue = selected[0] || ""
    }

    function poll() {
        loading = true
        errorText = ""
        var request = new XMLHttpRequest()
        request.open("GET", endpoint)
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE)
                return
            loading = false
            if (request.status < 200 || request.status >= 300) {
                errorText = i18n("Could not fetch schedule (%1)", request.status)
                return
            }
            var parsed = parseResponse(request.responseText)
            if (!parsed.length) {
                errorText = i18n("Schedule not found")
                return
            }
            schedules = parsed
            updateConfiguration(parsed)
            lastUpdated = Qt.formatTime(new Date(), "hh:mm")
            sendOutageAlert()
        }
        request.onerror = function() { loading = false; errorText = i18n("Network error") }
        request.send()
    }

    function minutes(time) {
        var parts = time.split(":")
        return Number(parts[0]) * 60 + Number(parts[1])
    }

    function intervalAt(item, now) {
        if (item.date.toDateString() !== now.toDateString())
            return null
        var current = now.getHours() * 60 + now.getMinutes()
        return item.intervals.find(function(interval) {
            var end = interval.end === "00:00" ? 1440 : minutes(interval.end)
            return current >= minutes(interval.start) && current < end
        })
    }

    function nextOutage() {
        var now = new Date()
        var priority = plasmoid.configuration.priorityQueue
        var rows = visibleSchedules().filter(function(item) { return item.queue === priority })
        if (!rows.length)
            rows = visibleSchedules()
        var result = null
        rows.forEach(function(item) {
            item.intervals.forEach(function(interval) {
                if (interval.state !== "off")
                    return
                var date = new Date(item.date)
                var parts = interval.start.split(":")
                date.setHours(Number(parts[0]), Number(parts[1]), 0, 0)
                if (date > now && (!result || date < result.date))
                    result = { date: date, time: interval.start, queue: item.queue }
            })
        })
        return result
    }

    function countdown(event) {
        var totalMinutes = minutesUntil(event)
        if (totalMinutes < 1) return i18n("<1 min")
        if (totalMinutes < 60) return i18n("%1 min", totalMinutes)
        return i18n("%1 h %2 min", Math.floor(totalMinutes / 60), totalMinutes % 60)
    }

    function minutesUntil(event) {
        return Math.ceil(Math.max(0, event.date - new Date()) / 60000)
    }

    function compactText() {
        var tick = clockTick
        var event = nextOutage()
        if (!event)
            return loading ? i18n("Updating…") : i18n("No upcoming outage")
        return event.time + " | " + countdown(event)
    }

    function sendOutageAlert() {
        var event = nextOutage()
        if (!event) {
            lastAlertKey = ""
            return
        }
        var remaining = minutesUntil(event)
        var threshold = remaining <= 5 ? 5 : remaining <= 10 ? 10 : remaining <= 20 ? 20 : 0
        if (!threshold)
            return
        var key = event.queue + "|" + event.date.getTime() + "|" + threshold
        if (key === lastAlertKey)
            return
        lastAlertKey = key
        outageNotification.eventId = key
        outageNotification.title = i18n("Power outage approaching")
        outageNotification.text = i18n("Queue %1: outage at %2 — approximately %3 minutes remaining.", event.queue, event.time, remaining)
        outageNotification.sendEvent()
    }

    function stateColor(state) {
        return state === "off" ? "#8f3d49" : state === "possible" ? "#8a6d1d" : "#3f7f4f"
    }

    Component.onCompleted: poll()

    Timer { interval: 30 * 60 * 1000; running: true; repeat: true; onTriggered: root.poll() }
    Timer { interval: 60 * 1000; running: true; repeat: true; onTriggered: { root.clockTick++; root.sendOutageAlert() } }

    Notification {
        id: outageNotification
        componentName: "poe-queue-widget"
        urgency: Notification.CriticalUrgency
        flags: Notification.Persistent | Notification.SkipGrouping
        autoDelete: true
    }

    Connections {
        target: plasmoid.configuration
        function onSelectedQueuesChanged() { root.clockTick++ }
        function onPriorityQueueChanged() { root.clockTick++ }
    }

    compactRepresentation: Item {
        id: compactView
        implicitWidth: compactLabel.implicitWidth
        implicitHeight: compactLabel.implicitHeight
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth
        Layout.minimumHeight: implicitHeight
        Layout.preferredHeight: implicitHeight
        Layout.maximumHeight: implicitHeight
        height: implicitHeight

        Text {
            id: compactLabel
            text: root.compactText()
            color: Kirigami.Theme.textColor
            anchors.centerIn: parent
        }

        MouseArea {
            anchors.fill: parent
            preventStealing: true
            onClicked: root.expanded = !root.expanded
        }
    }

    fullRepresentation: Flickable {
        id: view
        implicitWidth: 410
        implicitHeight: content.implicitHeight + 24
        Layout.preferredWidth: 410
        Layout.minimumHeight: 0
        Layout.preferredHeight: content.implicitHeight + 24
        Layout.maximumHeight: 560
        contentWidth: width
        contentHeight: content.implicitHeight + 24
        clip: true

        ColumnLayout {
            id: content
            x: 14
            width: Math.max(0, view.width - 28)
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label { text: i18n("Outage schedule"); font.bold: true; font.pointSize: 15; Layout.fillWidth: true }
                PlasmaComponents.ToolButton { icon.name: "view-refresh"; enabled: !root.loading; onClicked: root.poll() }
            }
            PlasmaComponents.Label {
                visible: root.loading || root.errorText.length > 0 || root.lastUpdated.length > 0
                text: root.loading ? i18n("Updating…") : root.errorText.length ? root.errorText : i18n("Updated at %1", root.lastUpdated)
                color: root.errorText.length ? "#e53935" : palette.text
                opacity: root.errorText.length ? 1 : 0.7
                Layout.fillWidth: true
            }

            Repeater {
                model: root.visibleSchedules()
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 5
                    PlasmaComponents.Label { text: modelData.queue + " · " + modelData.dateText; font.bold: true }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 3
                        Repeater {
                            model: modelData.intervals
                            delegate: Rectangle {
                                required property var modelData
                                width: intervalLabel.implicitWidth + 12
                                height: 26
                                radius: 4
                                color: root.stateColor(modelData.state)
                                PlasmaComponents.Label { id: intervalLabel; anchors.centerIn: parent; color: "#ffffff"; text: modelData.start + "–" + modelData.end; font.pointSize: 8; font.bold: modelData.state === "off" }
                                ToolTip.visible: intervalMouse.containsMouse
                                ToolTip.text: modelData.state === "off" ? i18n("Outage") : modelData.state === "possible" ? i18n("Possible outage") : i18n("Power available")
                                MouseArea { id: intervalMouse; anchors.fill: parent; hoverEnabled: true }
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: "#66808080" }
                }
            }

            PlasmaComponents.Label {
                visible: !root.loading && root.errorText.length === 0 && root.schedules.length === 0
                text: i18n("No data")
            }
        }
    }
}

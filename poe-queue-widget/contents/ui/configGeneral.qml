import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami

Kirigami.FormLayout {
    id: page

    property string title: ""
    property string cfg_selectedQueues: plasmoid.configuration.selectedQueues
    property string cfg_selectedQueuesDefault: "1.1,1.2"
    property string cfg_priorityQueue: plasmoid.configuration.priorityQueue
    property string cfg_priorityQueueDefault: "1.1"
    readonly property var queueNames: ["1.1", "1.2", "2.1", "2.2", "3.1", "3.2", "4.1", "4.2", "5.1", "5.2", "6.1", "6.2"]

    function selectedQueues() {
        return cfg_selectedQueues.split(",").filter(function(queue) { return queue.length > 0 })
    }

    function setQueueSelected(queue, selected) {
        var queues = selectedQueues()
        var index = queues.indexOf(queue)
        if (selected && index === -1)
            queues.push(queue)
        else if (!selected && index !== -1 && queues.length > 1)
            queues.splice(index, 1)
        cfg_selectedQueues = queues.join(",")
        plasmoid.configuration.selectedQueues = cfg_selectedQueues
        if (queues.indexOf(cfg_priorityQueue) === -1) {
            cfg_priorityQueue = queues[0]
            plasmoid.configuration.priorityQueue = cfg_priorityQueue
        }
    }

    GridLayout {
        Kirigami.FormData.label: i18n("Queues")
        Layout.fillWidth: true
        columns: 6
        columnSpacing: Kirigami.Units.smallSpacing
        rowSpacing: 0

        Repeater {
            model: page.queueNames
            delegate: QQC2.CheckBox {
                required property string modelData
                required property int index
                text: modelData
                Layout.column: Math.floor(index / 2)
                Layout.row: index % 2
                checked: page.selectedQueues().indexOf(modelData) !== -1
                onToggled: {
                    if (!checked && page.selectedQueues().length === 1) {
                        checked = true
                        return
                    }
                    page.setQueueSelected(modelData, checked)
                }
            }
        }
    }

    QQC2.Label {
        text: i18n("Select one or more queues.")
        opacity: 0.7
        Layout.fillWidth: true
    }

    QQC2.ComboBox {
        id: priorityCombo
        Kirigami.FormData.label: i18n("Priority queue")
        Layout.fillWidth: true
        model: page.queueNames
        currentIndex: Math.max(0, page.queueNames.indexOf(page.cfg_priorityQueue))
        onActivated: {
            page.cfg_priorityQueue = currentText
            plasmoid.configuration.priorityQueue = page.cfg_priorityQueue
        }
    }

    QQC2.Label {
        text: i18n("The compact view shows the time until the next outage for this queue.")
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
}

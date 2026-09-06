import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 8000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#1e1e2e"
            Column {
                anchors.centerIn: parent
                spacing: 18
                Text {
                    text: "starch"
                    color: "#cba6f7"
                    font.pixelSize: 48
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: "Arch Linux, with Hyprland already set up."
                    color: "#cdd6f4"
                    font.pixelSize: 20
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#1e1e2e"
            Column {
                anchors.centerIn: parent
                spacing: 18
                Text {
                    text: "When this finishes, it is just Arch."
                    color: "#cba6f7"
                    font.pixelSize: 32
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: "pacman, the Arch wiki, and the AUR all work the way\nthey do everywhere else. Nothing here replaces them."
                    color: "#cdd6f4"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}

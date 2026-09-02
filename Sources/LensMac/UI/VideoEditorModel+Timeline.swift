import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
    func selectSegment(_ id: UUID) {
        guard timeline.segments.contains(where: { $0.id == id }) else { return }
        selectedSegmentID = id
    }

    func split(atOutputTime outputTime: Double) {
        guard let position = timeline.position(atOutputTime: outputTime) else { return }
        mutate(timelineChanged: true) { plan in
            guard var timeline = plan.timeline,
                  let newID = timeline.split(
                    segmentID: position.segmentID,
                    atSourceTime: position.sourceTimeSeconds
                  ) else { return }
            plan.timeline = timeline
            selectedSegmentID = newID
        }
    }

    func trimSelectedStart(toOutputTime outputTime: Double) {
        guard let selectedSegmentID,
              let position = timeline.position(atOutputTime: outputTime),
              position.segmentID == selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.trimStart(
                of: selectedSegmentID,
                to: position.sourceTimeSeconds
            )
        }
    }

    func trimSelectedEnd(toOutputTime outputTime: Double) {
        guard let selectedSegmentID,
              let position = timeline.position(atOutputTime: outputTime),
              position.segmentID == selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.trimEnd(
                of: selectedSegmentID,
                to: position.sourceTimeSeconds
            )
        }
    }

    func removeSelectedSegment() {
        guard let selectedSegmentID, canRemoveSelectedSegment else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setEnabled(false, for: selectedSegmentID)
        }
        self.selectedSegmentID = activeSegments.first?.id
    }

    func setSelectedPlaybackRate(_ rate: Double) {
        guard let selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setPlaybackRate(rate, for: selectedSegmentID)
        }
    }

    func setSelectedTransitionKind(_ kind: VideoEditTransition.Kind) {
        guard let selectedSegmentID, canTransitionFromSelectedSegment else { return }
        let duration = selectedTransitionDuration
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setTransition(
                kind == .cut
                    ? nil
                    : VideoEditTransition(kind: kind, durationSeconds: duration),
                after: selectedSegmentID
            )
        }
    }

    func setSelectedTransitionDuration(_ duration: Double) {
        guard let selectedSegmentID,
              canTransitionFromSelectedSegment,
              selectedTransitionKind != .cut else { return }
        let kind = selectedTransitionKind
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setTransition(
                VideoEditTransition(kind: kind, durationSeconds: duration),
                after: selectedSegmentID
            )
        }
    }
}

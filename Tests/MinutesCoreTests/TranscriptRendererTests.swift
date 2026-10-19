import Foundation
import Testing
import MinutesCore

@Suite struct TranscriptRendererTests {
    private func metadata(title: String? = "Cliente X", hasVideo: Bool = true) -> MeetingMetadata {
        var metadata = MeetingMetadata(
            appName: "Zoom", appBundleID: "us.zoom.xos", title: title, windowTitle: "Zoom Meeting",
            trigger: "auto", startedAt: isoDate("2026-10-19T08:30:00Z"), hasVideo: hasVideo
        )
        metadata.durationSeconds = 2730.5
        metadata.videoOffsetSeconds = 0.4
        return metadata
    }

    private func segment(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    @Test func speakerLabelsAreYoAndEllos() {
        #expect(Speaker.me.rawValue == "Yo")
        #expect(Speaker.them.rawValue == "Ellos")
    }

    @Test func timestampIsFlooredHoursMinutesSecondsWithoutWrapping() {
        #expect(TranscriptRenderer.timestamp(0) == "00:00:00")
        #expect(TranscriptRenderer.timestamp(3.99) == "00:00:03")
        #expect(TranscriptRenderer.timestamp(3725) == "01:02:05")
        #expect(TranscriptRenderer.timestamp(90_000) == "25:00:00")
        #expect(TranscriptRenderer.timestamp(-5) == "00:00:00")
    }

    @Test func markdownRendersTheHeaderAndOneLinePerSpeakerTurn() {
        let segments = [
            segment(.them, 3, 4.5, "Hola, ¿me oyes?"),
            segment(.me, 5, 6, "Sí, perfecto."),
        ]
        let expected = """
        # Cliente X — 2026-10-19 10:30

        - App: Zoom
        - Duración: 00:45:30
        - Vídeo: video.mp4 (desfase +0.4 s)
        - Audio: yo.m4a (Yo), ellos.m4a (Ellos)

        ## Transcripción

        [00:00:03] Ellos: Hola, ¿me oyes?
        [00:00:05] Yo: Sí, perfecto.

        """
        #expect(TranscriptRenderer.markdown(segments, metadata: metadata(), timeZone: madrid) == expected)
    }

    @Test func markdownJoinsSameSpeakerSegmentsSeparatedByAtMostTwoSeconds() {
        let segments = [
            segment(.me, 0, 2, "Hola"),
            segment(.me, 4, 5, "qué tal"),
            segment(.me, 7.1, 8, "Bien."),
            segment(.them, 8.5, 9, "Genial"),
            segment(.them, 9.5, 10, "entonces."),
        ]
        let transcript = TranscriptRenderer.markdown(segments, metadata: metadata(), timeZone: madrid)
        #expect(transcript.hasSuffix("""
        ## Transcripción

        [00:00:00] Yo: Hola qué tal
        [00:00:07] Yo: Bien.
        [00:00:08] Ellos: Genial entonces.

        """))
    }

    @Test func markdownFallsBackForMissingTitleDurationVideoAndSpeech() {
        var noVideo = metadata(title: nil, hasVideo: false)
        noVideo.durationSeconds = nil
        let expected = """
        # Zoom — 2026-10-19 08:30

        - App: Zoom
        - Duración: desconocida
        - Audio: yo.m4a (Yo), ellos.m4a (Ellos)

        ## Transcripción

        _Sin transcripción (no se detectó voz)._

        """
        #expect(TranscriptRenderer.markdown([], metadata: noVideo, timeZone: utc) == expected)

        var unknownOffset = metadata()
        unknownOffset.videoOffsetSeconds = nil
        #expect(TranscriptRenderer.markdown([], metadata: unknownOffset, timeZone: utc)
            .contains("\n- Vídeo: video.mp4 (desfase +0.0 s)\n"))
        var negativeOffset = metadata()
        negativeOffset.videoOffsetSeconds = -1.26
        #expect(TranscriptRenderer.markdown([], metadata: negativeOffset, timeZone: utc)
            .contains("\n- Vídeo: video.mp4 (desfase -1.3 s)\n"))
    }

    @Test func jsonHoldsTheMeetingAndTheExactSegments() throws {
        let segments = [segment(.them, 3.25, 4.5, "Hola"), segment(.me, 5, 6, "Sí")]
        let data = try TranscriptRenderer.json(segments, metadata: metadata())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasPrefix("{\n  \"meeting\" : {"))
        #expect(text.contains("\"startedAt\" : \"2026-10-19T08:30:00"))

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["meeting", "segments"])
        let meeting = try #require(object["meeting"] as? [String: Any])
        #expect(meeting["appName"] as? String == "Zoom")
        let decodedSegments = try #require(object["segments"] as? [[String: Any]])
        #expect(decodedSegments.count == 2)
        #expect(decodedSegments[0]["speaker"] as? String == "Ellos")
        #expect(decodedSegments[0]["start"] as? Double == 3.25)
        #expect(decodedSegments[0]["end"] as? Double == 4.5)
        #expect(decodedSegments[1]["speaker"] as? String == "Yo")
        #expect(decodedSegments[1]["text"] as? String == "Sí")
    }
}

import AVFoundation
import NatterCore
import FluidAudio
import Foundation

/// One Parakeet Unified checkpoint, two decode paths: a chunked-attention
/// streaming encoder feeds the live overlay preview, and the full-attention
/// offline encoder decodes the retained session audio at stop to produce the
/// transcript that is actually delivered (better WER than any streaming pass).
actor SpeechTranscriber {
    private let streamingConfig = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1)
    private let finalizer = UnifiedAsrManager()
    private let preview: StreamingUnifiedAsrManager
    private var retainedSamples: [Float] = []
    private var pendingPreviewSamples: [Float] = []
    private var lastPreviewTranscript = ""
    private var previewFailed = false
    private var previewDirectory: URL?
    private var finalizerDirectory: URL?
    private var finalizerLoadTask: Task<Void, Error>?

    init() {
        preview = StreamingUnifiedAsrManager(config: streamingConfig)
    }

    /// Loads the streaming encoder so listening can start, then kicks off the
    /// offline encoder in the background. The previous path loaded both and
    /// ran a blocking silence transcribe before returning, so the first
    /// dictation sat on "Loading local speech model…" until CoreML finished
    /// compiling ~2 GB of graphs.
    func prepare(modelDirectory: URL) async throws {
        try await ensurePreview(modelDirectory)
        startFinalizerLoad(modelDirectory)
    }

    func install(
        to modelsDirectory: URL,
        progressHandler: @escaping ProgressHandler
    ) async throws {
        try await preview.loadModels(to: modelsDirectory, progressHandler: progressHandler)
        let directory = modelsDirectory.appendingPathComponent(
            SpeechModelLocation.relativePath,
            isDirectory: true
        )
        previewDirectory = directory
        try await finalizer.loadModels(from: directory)
        finalizerDirectory = directory
        finalizerLoadTask = nil
    }

    func unload() async {
        finalizerLoadTask?.cancel()
        finalizerLoadTask = nil
        await finalizer.cleanup()
        await preview.cleanup()
        retainedSamples.removeAll()
        pendingPreviewSamples.removeAll()
        lastPreviewTranscript = ""
        previewDirectory = nil
        finalizerDirectory = nil
    }

    func reset() async {
        retainedSamples.removeAll()
        pendingPreviewSamples.removeAll()
        lastPreviewTranscript = ""
        previewFailed = false
        try? await finalizer.reset()
        try? await preview.reset()
    }

    /// Buffers session audio for the batch pass and advances the streaming
    /// preview. Preview failures are non-fatal: the final transcript only
    /// depends on the retained audio, so a broken preview must never kill a
    /// dictation that the batch decode could still rescue.
    func consume(_ chunk: AudioChunk) async throws -> String {
        retainedSamples.append(contentsOf: chunk.samples)
        guard !previewFailed else { return lastPreviewTranscript }
        pendingPreviewSamples.append(contentsOf: chunk.samples)
        guard pendingPreviewSamples.count >= streamingConfig.chunkSamples else {
            return lastPreviewTranscript
        }
        let samples = pendingPreviewSamples
        pendingPreviewSamples.removeAll(keepingCapacity: true)
        do {
            try await preview.appendAudio(
                AudioChunk(samples: samples, sampleRate: chunk.sampleRate).makeBuffer()
            )
            try await preview.processBufferedAudio()
            lastPreviewTranscript = await preview.getPartialTranscript()
        } catch {
            previewFailed = true
            NatterLog.model.error(
                "speech preview failed, batch decode still active error=\(error.localizedDescription, privacy: .public)"
            )
        }
        return lastPreviewTranscript
    }

    func finish() async throws -> String {
        if let previewDirectory {
            try await ensureFinalizer(previewDirectory)
        }
        let transcript = try await finalizer.transcribe(retainedSamples)
        await reset()
        return transcript
    }

    private func ensurePreview(_ directory: URL) async throws {
        guard previewDirectory != directory else { return }
        try await preview.loadModels(from: directory)
        previewDirectory = directory
    }

    private func startFinalizerLoad(_ directory: URL) {
        guard finalizerDirectory != directory, finalizerLoadTask == nil else { return }
        let finalizer = finalizer
        finalizerLoadTask = Task {
            try await finalizer.loadModels(from: directory)
        }
    }

    private func ensureFinalizer(_ directory: URL) async throws {
        if finalizerDirectory == directory { return }
        if let finalizerLoadTask {
            self.finalizerLoadTask = nil
            do {
                try await finalizerLoadTask.value
                finalizerDirectory = directory
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NatterLog.model.error(
                    "offline speech model preload failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        try await finalizer.loadModels(from: directory)
        finalizerDirectory = directory
    }
}

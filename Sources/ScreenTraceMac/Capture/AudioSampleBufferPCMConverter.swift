import AVFoundation
import CoreMedia
import Foundation

enum AudioSampleBufferConversionError: LocalizedError {
    case incompatibleFormat(String)

    var errorDescription: String? {
        switch self {
        case let .incompatibleFormat(detail):
            "系统音频 PCM 转换失败：\(detail)"
        }
    }
}

/// Converts ScreenCaptureKit's potentially planar audio sample buffers into
/// an owned AVAudioPCMBuffer. Reading the source AudioBufferList is important:
/// SCK buffers do not always expose the ordinary CMBlockBuffer required by
/// CMSampleBufferCopyPCMDataIntoAudioBufferList.
enum AudioSampleBufferPCMConverter {
    static func convert(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioSampleBufferConversionError.incompatibleFormat(
                "missing format description"
            )
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(
            CMSampleBufferGetNumSamples(sampleBuffer)
        )
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ) else {
            throw AudioSampleBufferConversionError.incompatibleFormat(
                "buffer allocation failed; frames=\(frameCount), channels=\(format.channelCount), commonFormat=\(format.commonFormat.rawValue), interleaved=\(format.isInterleaved)"
            )
        }
        // AVAudioPCMBuffer exposes zero writable bytes while frameLength is
        // zero, even though its channel storage has already been allocated.
        buffer.frameLength = frameCount

        var sourceBufferListSize = 0
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sourceBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizingStatus == noErr,
              sourceBufferListSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioSampleBufferConversionError.incompatibleFormat(
                "buffer-list sizing OSStatus=\(sizingStatus), bytes=\(sourceBufferListSize); frames=\(frameCount), channels=\(format.channelCount), commonFormat=\(format.commonFormat.rawValue), interleaved=\(format.isInterleaved)"
            )
        }

        let sourceStorage = UnsafeMutableRawPointer.allocate(
            byteCount: sourceBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { sourceStorage.deallocate() }
        let sourceListPointer = sourceStorage.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )
        var retainedBlockBuffer: CMBlockBuffer?
        let extractionStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceListPointer,
            bufferListSize: sourceBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard extractionStatus == noErr else {
            throw AudioSampleBufferConversionError.incompatibleFormat(
                "buffer-list extraction OSStatus=\(extractionStatus); frames=\(frameCount), channels=\(format.channelCount), commonFormat=\(format.commonFormat.rawValue), interleaved=\(format.isInterleaved)"
            )
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceListPointer)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioSampleBufferConversionError.incompatibleFormat(
                "plane mismatch; source=\(sourceBuffers.count), destination=\(destinationBuffers.count), channels=\(format.channelCount), interleaved=\(format.isInterleaved)"
            )
        }
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            var destination = destinationBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destination.mData,
                  source.mDataByteSize <= destination.mDataByteSize else {
                throw AudioSampleBufferConversionError.incompatibleFormat(
                    "plane \(index) is invalid or exceeds capacity; sourceBytes=\(source.mDataByteSize), destinationBytes=\(destination.mDataByteSize)"
                )
            }
            destinationData.copyMemory(
                from: sourceData,
                byteCount: Int(source.mDataByteSize)
            )
            destination.mDataByteSize = source.mDataByteSize
            destinationBuffers[index] = destination
        }
        return buffer
    }
}

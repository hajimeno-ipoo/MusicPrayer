import AVFoundation
import Foundation

enum AppleMusicTimeExpansion {
    /// Restore the original timeline of pitch-preserving 2x capture without changing sample-rate labels.
    /// This manual-rendering engine has no device output. Returned audio remains in RAM.
    static func expand(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try render(source).buffer
    }

    static func render(_ source: AVAudioPCMBuffer) throws -> (buffer: AVAudioPCMBuffer, diagnostics: [String: Double]) {
        let rate=source.format.sampleRate
        guard rate>0,source.frameLength>0,source.format.commonFormat == .pcmFormatFloat32,
              !source.format.isInterleaved else { throw failure("invalid input") }
        let format=source.format,channels=Int(format.channelCount)
        // Quiet pre/post-roll gives the time-stretch window material on both sides of the real source.
        let padding=Int((rate*0.25).rounded()),n=Int(source.frameLength),expected=n*2
        guard let quiet=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(padding)) else {throw failure("allocate quiet padding")}
        quiet.frameLength=quiet.frameCapacity
        for c in 0..<channels { quiet.floatChannelData![c].initialize(repeating:0,count:padding) }
        let engine=AVAudioEngine(),player=AVAudioPlayerNode(),stretch=AVAudioUnitTimePitch()
        // Configure manual mode before touching the main mixer/output, avoiding device-rendering setup.
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        engine.attach(player);engine.attach(stretch)
        stretch.rate=0.5;stretch.pitch=0
        // Apple recommends lower smoothness when slowing percussive audio. The same live input
        // retained drum activity better at 3 than 8.
        stretch.overlap=3
        engine.connect(player,to:stretch,format:format)
        engine.connect(stretch,to:engine.mainMixerNode,format:format)
        player.scheduleBuffer(quiet,at:nil,options:[])
        player.scheduleBuffer(source,at:nil,options:[])
        player.scheduleBuffer(quiet,at:nil,options:[])
        try engine.start();player.play()
        defer{player.stop();engine.stop()}
        let latency=stretch.latency
        let latencyFrames=Int((latency*rate).rounded())
        let first=padding*2+latencyFrames
        let total=first+expected+padding*2
        guard let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096),
              let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(expected)) else {throw failure("allocate output")}
        var position=0,retries=0
        while position<total {
            try Task.checkCancellation()
            let request=AVAudioFrameCount(min(4096,total-position))
            let status=try engine.renderOffline(request,to:block)
            if block.frameLength>0 {
                let count=Int(block.frameLength)
                let lower=max(position,first),upper=min(position+count,first+expected)
                if upper>lower {
                    for c in 0..<channels {
                        memcpy(output.floatChannelData![c]+(lower-first),block.floatChannelData![c]+(lower-position),(upper-lower)*4)
                    }
                }
                position += count;retries=0
            } else {
                retries += 1
                if retries>32 {throw failure("render made no progress: \(status.rawValue)")}
            }
            if status == .error {throw failure("render failed")}
        }
        output.frameLength=AVAudioFrameCount(expected)
        return(output,["sampleRate":rate,"inputFrames":Double(n),"outputFrames":Double(expected),"unitLatencySeconds":latency,"trimmedFrames":Double(first),"paddingInputFrames":Double(padding),"renderedFrames":Double(position)])
    }
    private static func failure(_ message:String)->NSError{NSError(domain:"AppleMusicTimeExpansion",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}

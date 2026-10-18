import JavaScriptCore
import XCTest
@testable import MusicPrayer

final class AppleMusicBridgeTests: XCTestCase {
    @MainActor
    func testAnalysisKeepsFastRateAfterPageResetsRateOrReplacesMedia() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var listeners={};
        var media={id:'apple-music-player',currentTime:12,readyState:4,playbackRate:1,defaultPlaybackRate:1,preservesPitch:true};
        var document={addEventListener:(name,callback)=>{listeners[name]=callback},getElementById:()=>media};
        var player={playbackRate:1,isPlaying:false,currentPlaybackDuration:90,nowPlayingItem:{id:'123'}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        _ = try await execute("analysisRate", value: 2, in: context)
        context.evaluateScript("media.playbackRate=1;listeners.ratechange?.({target:media});")
        XCTAssertEqual(context.evaluateScript("media.playbackRate")?.toDouble(), 2, "ページが再生速度を戻しても事前解析中は2倍へ戻す")
        context.evaluateScript("media={id:'apple-music-player',currentTime:20,readyState:4,playbackRate:1,defaultPlaybackRate:1,preservesPitch:false};listeners.play?.({target:media});")
        XCTAssertEqual(context.evaluateScript("media.playbackRate")?.toDouble(), 2, "差し替えられた再生要素にも実際の速度を適用する")
        XCTAssertEqual(context.evaluateScript("media.preservesPitch")?.toBool(), true)
        _ = try await execute("analysisRate", value: 1, in: context)
        context.evaluateScript("listeners.ratechange?.({target:media});listeners.play?.({target:media});")
        XCTAssertEqual(context.evaluateScript("media.playbackRate")?.toDouble(), 1, "終了後の通常再生には2倍の制御を残さない")
        XCTAssertEqual(context.evaluateScript("media.defaultPlaybackRate")?.toDouble(), 1)
    }

    @MainActor
    func testAnalysisRatePreservesPitchAndRestoresNormalPlayback() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var media={currentTime:12,readyState:4,playbackRate:1,preservesPitch:true};
        var document={addEventListener:()=>{},getElementById:()=>media};
        var player={playbackRate:1,isPlaying:false,currentPlaybackDuration:90,nowPlayingItem:{id:'123'}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let fast = try AppleMusicBridge.decode(await execute("analysisRate", value: 2, in: context))
        XCTAssertEqual(fast.playbackRate, 2)
        XCTAssertEqual(fast.preservesPitch, true)
        XCTAssertEqual(context.evaluateScript("player.playbackRate")?.toDouble(), 2)
        let normal = try AppleMusicBridge.decode(await execute("analysisRate", value: 1, in: context))
        XCTAssertEqual(normal.playbackRate, 1)
        XCTAssertEqual(normal.preservesPitch, true)
    }

    @MainActor
    func testSnapshotUsesFractionalMediaClockForContinuousMotion() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var media={currentTime:12.34567,readyState:4};
        var document={addEventListener:()=>{},getElementById:id=>id==='apple-music-player'?media:null};
        var player={isPlaying:true,currentPlaybackTime:12,currentPlaybackDuration:90,nowPlayingItem:{id:'123'}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let playing = try await run("snapshot", in: context)
        XCTAssertEqual(playing.time, 12.34567, accuracy: 0.000001)
        context.evaluateScript("player.isPlaying=false;media.currentTime=12.45678;")
        let paused = try await run("snapshot", in: context)
        XCTAssertEqual(paused.time, 12.45678, accuracy: 0.000001)
        context.evaluateScript("media.readyState=0;")
        let preparing = try await run("snapshot", in: context)
        XCTAssertEqual(preparing.time, 12)
    }

    @MainActor
    func testLyricsUsesSelectedSongRelationshipAndKeepsTTML() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var calls=[];
        var documentText='<tt><body><p begin="1s" end="3s">テスト</p></body></tt>';
        var player={storefrontId:'jp',api:{music:async(path,parameters)=>{
            calls.push({path,parameters});
            return {data:{data:[{id:'123',relationships:{lyrics:{data:[{id:'123',type:'lyrics'}]}}}],
                included:[{id:'123',type:'lyrics',attributes:{ttml:documentText}}]}};
        }}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let value = try await execute("lyrics", value: "123", in: context)
        let response = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(response["songID"] as? String, "123")
        XCTAssertEqual(response["ttml"] as? String, context.objectForKeyedSubscript("documentText")?.toString())
        let calls = try XCTUnwrap(context.objectForKeyedSubscript("calls")?.toArray() as? [[String: Any]])
        XCTAssertEqual(calls.first?["path"] as? String, "/v1/catalog/jp/songs/123")
        XCTAssertEqual((calls.first?["parameters"] as? [String: Any])?["include"] as? String, "syllable-lyrics,lyrics")
    }

    @MainActor
    func testLyricsUsesWordTimingResourceBeforeLineTimingInIncludedResults() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var player={storefrontId:'jp',api:{music:async()=>({data:{data:[{relationships:{lyrics:{data:[{type:'lyrics',attributes:{ttml:'line'}}]}}}],included:[{type:'syllable-lyrics',attributes:{ttml:'word'}}]}})}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let value = try await execute("lyrics", value: "123", in: context)
        let response = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(response["ttml"] as? String, "word")
    }

    @MainActor
    func testLyricsWithoutResourceReturnsNoLyricsAndRejectsInvalidID() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var calls=0;
        var player={storefrontId:'jp',api:{music:async()=>{calls++;return {data:{data:[{id:'123'}]}};}}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let value = try await execute("lyrics", value: "123", in: context)
        let response = try XCTUnwrap(value as? [String: Any])
        XCTAssertTrue(response["ttml"] is NSNull)
        do { _ = try await execute("lyrics", value: "../other", in: context); XCTFail("不正な曲IDで通信しない") } catch {}
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toInt32(), 1)
    }

    @MainActor
    func testOfficialPageBridgeReadsMetadataAndControlsExistingPlayer() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location = { protocol: 'https:', hostname: 'music.apple.com' };
        var calls = [];
        var player = {
            isPlaying: false, currentPlaybackTime: 12, currentPlaybackDuration: 90, volume: .5,
            nowPlayingItem: { title: '曲名', artistName: '歌手', attributes: { artwork: { url: 'https://example.com/{w}x{h}.jpg' } } },
            queue: { nextPlayableItem: {}, previousPlayableItem: null },
            play: async function() { this.isPlaying = true; calls.push('play'); },
            pause: async function() { this.isPlaying = false; calls.push('pause'); },
            stop: async function() { this.isPlaying = false; this.currentPlaybackTime = 0; calls.push('stop'); },
            seekToTime: async function(time) { this.currentPlaybackTime = time; calls.push('seek'); },
            skipToNextItem: async function() { calls.push('next'); },
            skipToPreviousItem: async function() { calls.push('previous'); }
        };
        var window = { MusicKit: { getInstance: () => player } };
        """)
        let snapshot = try await run("snapshot", in: context)
        XCTAssertEqual(snapshot.title, "曲名")
        XCTAssertEqual(snapshot.artist, "歌手")
        XCTAssertEqual(snapshot.artworkURL, "https://example.com/600x600.jpg")
        XCTAssertTrue(snapshot.canPrevious)
        XCTAssertTrue(snapshot.canNext)
        let playing = try await run("toggle", in: context)
        XCTAssertTrue(playing.isPlaying)
        let paused = try await run("toggle", in: context)
        XCTAssertFalse(paused.isPlaying)
        let seek = try await run("seek", value: 999, in: context)
        XCTAssertEqual(seek.time, 90)
        _ = try await run("volume", value: -1, in: context)
        XCTAssertEqual(context.objectForKeyedSubscript("player")?.forProperty("volume")?.toDouble(), 0)
        let previous = try await run("previous", in: context)
        XCTAssertEqual(previous.time, 0)
        XCTAssertFalse(previous.canPrevious)
        _ = try await run("previous", in: context)
        _ = try await run("next", in: context)
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toArray() as? [String], ["play", "pause", "seek", "seek", "next"])
    }

    @MainActor
    func testBridgeRejectsOtherOriginsAndMissingPlayerWithoutReadingPageState() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var location = {protocol:'https:',hostname:'account.apple.com'}; var window = {get MusicKit() {throw new Error('must not read');}};")
        let otherOrigin = try await run("snapshot", in: context)
        XCTAssertFalse(otherOrigin.available)
        context.evaluateScript("location.hostname = 'music.apple.com'; window = {};")
        let absent = try await run("snapshot", in: context)
        XCTAssertFalse(absent.available)
        XCTAssertEqual(absent.time, 0)
    }

    @MainActor
    func testSearchPassesQueryAsDataAndMapsCatalogResults() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location = {protocol:'https:',hostname:'music.apple.com'};
        var calls = [];
        var song = {id:'123',attributes:{name:'愛が止まらない',artistName:'Wink',albumName:'アルバム',durationInMillis:209000,artwork:{url:'https://example.com/{w}x{h}.jpg'}}};
        var api = {music:async (path, parameters)=>{
            calls.push({path, parameters});
            return {data:{results:{songs:{data:[song]}}}};
        }};
        var window = {MusicKit:{getInstance:()=>({storefrontId:'jp',api:api})}};
        """)
        let query = "  Wink ' 愛が止まらない  "
        let value = try await execute("search", value: query, in: context)
        let result = try JSONDecoder().decode(AppleMusicSearchResult.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.songs.first?.title, "愛が止まらない")
        XCTAssertEqual(result.songs.first?.artist, "Wink")
        XCTAssertEqual(result.songs.first?.duration, 209)
        XCTAssertEqual(result.songs.first?.artworkURL, "https://example.com/300x300.jpg")
        let calls = try XCTUnwrap(context.objectForKeyedSubscript("calls")?.toArray() as? [[String: Any]])
        XCTAssertEqual(calls.first?["path"] as? String, "/v1/catalog/jp/search")
        let parameters = try XCTUnwrap(calls.first?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["term"] as? String, query.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(parameters["types"] as? String, "songs")
        XCTAssertEqual(parameters["limit"] as? Int, 25)
        _ = try await execute("search", value: "  ", in: context)
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toArray()?.count, 1)
    }

    @MainActor
    func testSelectedCatalogSongSetsQueueBeforePlayAndRejectsInvalidID() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location = {protocol:'https:',hostname:'music.apple.com'};
        var calls = [];
        var player = {isAuthorized:true,isPlaying:false,currentPlaybackTime:0,currentPlaybackDuration:209,
            setQueue:async function(q){calls.push('queue:'+q.song);this.nowPlayingItem={title:'選んだ曲',artistName:'歌手'};},
            play:async function(){calls.push('play');this.isPlaying=true;}};
        var window = {MusicKit:{getInstance:()=>player}};
        """)
        let playback = try AppleMusicBridge.decode(await execute("playSong", value: "123", in: context))
        XCTAssertTrue(playback.isReady)
        XCTAssertTrue(playback.isAuthorized)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.title, "選んだ曲")
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toArray() as? [String], ["queue:123", "play"])
        do {
            _ = try await execute("playSong", value: "123');throw Error('unexpected')", in: context)
            XCTFail("不正なIDは再生へ渡さない")
        } catch {}
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toArray()?.count, 2)
    }

    @MainActor
    func testExpiredSelectionDoesNotStartPlaybackAfterQueueCompletes() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location = {protocol:'https:',hostname:'music.apple.com'};
        var played = false;
        var invocationIsCurrent = () => false;
        var window = {MusicKit:{getInstance:()=>({
            setQueue:async function(){}, play:async function(){played=true;}
        })}};
        """)
        do {
            _ = try await execute("playSong", value: "123", in: context)
            XCTFail("期限が切れた選曲は再生しない")
        } catch {}
        XCTAssertFalse(context.objectForKeyedSubscript("played")?.toBool() ?? true)
    }

    @MainActor
    func testPreparingRegisteredSongDoesNotAutoplayAndUsesAppQueuePolicy() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var calls=[];
        var player={isPlaying:false,autoplayEnabled:true,shuffleMode:1,repeatMode:1,
            setQueue:async function(q){calls.push('queue:'+q.song);this.nowPlayingItem={id:q.song,title:'登録曲'};},
            play:async function(){calls.push('play');this.isPlaying=true;},
            pause:async function(){calls.push('pause');this.isPlaying=false;}};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        let playback = try AppleMusicBridge.decode(await execute("prepareSong", value: "123", in: context))
        XCTAssertTrue(playback.available)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.id, "123")
        XCTAssertEqual(context.objectForKeyedSubscript("calls")?.toArray() as? [String], ["queue:123", "pause"])
        XCTAssertFalse(context.objectForKeyedSubscript("player")?.forProperty("autoplayEnabled")?.toBool() ?? true)
        XCTAssertEqual(context.objectForKeyedSubscript("player")?.forProperty("repeatMode")?.toInt32(), 0)
        XCTAssertEqual(context.objectForKeyedSubscript("player")?.forProperty("shuffleMode")?.toInt32(), 0)
    }

    @MainActor
    func testMediaEndStaysVisibleAfterOfficialPlayerClearsCurrentItem() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var location={protocol:'https:',hostname:'music.apple.com'};
        var endedHandler;
        var document={addEventListener:(name,handler)=>{if(name==='ended') endedHandler=handler;}};
        var player={nowPlayingItem:{id:'123',title:'登録曲'},isPlaying:true,currentPlaybackTime:90,currentPlaybackDuration:90};
        var window={MusicKit:{getInstance:()=>player}};
        """)
        _ = try await run("snapshot", in: context)
        context.evaluateScript("endedHandler({target:{id:'apple-music-player'}});player.nowPlayingItem=null;player.isPlaying=false;player.currentPlaybackTime=0;player.currentPlaybackDuration=0;")
        let ended = try await run("snapshot", in: context)
        XCTAssertTrue(ended.ended)
        XCTAssertEqual(ended.id, "123")
    }

    @MainActor
    private func run(_ command: String, value: Double = 0, in context: JSContext) async throws -> AppleMusicPlayback {
        try AppleMusicBridge.decode(await execute(command, value: value, in: context))
    }

    @MainActor
    private func execute(_ command: String, value: Any = 0, in context: JSContext) async throws -> Any {
        context.setObject(command, forKeyedSubscript: "testCommand" as NSString)
        context.setObject(value, forKeyedSubscript: "testValue" as NSString)
        context.evaluateScript("var result = null; var failure = null; (async function(command, value) {\(AppleMusicBridge.source)})(testCommand, testValue).then(x => result = JSON.stringify(x), e => failure = String(e));")
        for _ in 0..<100 {
            if let failure = context.objectForKeyedSubscript("failure"), !failure.isNull { throw NSError(domain: "JavaScript", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.toString() ?? "Error"]) }
            if let result = context.objectForKeyedSubscript("result"), !result.isNull, let text = result.toString() {
                let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AppleMusicBridgeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: context.exception?.toString() ?? "JavaScript did not finish"])
    }
}

// Runs only in the official page. Authentication and audio stay in its existing player.
if (location.protocol !== "https:" || location.hostname !== "music.apple.com") return null;
let music;
try { music = window.MusicKit?.getInstance(); } catch { return null; }
if (!music) {
    if (command === "search" || command === "playSong" || command === "prepareSong") throw new Error("Apple Music is not ready");
    return null;
}

// The official page clears the current item after completion. Keep the completion event
// until the app advances its own queue instead of relying on a later polling sample.
if (!window.__musicPrayerQueueState || window.__musicPrayerQueueState.music !== music) {
    const state = { music, lastID: "", completedID: null, analysisRate: null };
    state.applyAnalysisRate = media => {
        if (state.analysisRate !== 2 || media?.id !== "apple-music-player") return;
        if ('playbackRate' in music && music.playbackRate !== 2) Reflect.set(music, 'playbackRate', 2);
        media.preservesPitch = true;
        if (media.defaultPlaybackRate !== 2) media.defaultPlaybackRate = 2;
        if (media.playbackRate !== 2) media.playbackRate = 2;
    };
    window.__musicPrayerQueueState = state;
    if (typeof document !== "undefined") {
        document.addEventListener("ended", event => {
            if (event.target?.id === "apple-music-player" && state.lastID) state.completedID = state.lastID;
        }, true);
        // MusicKit can reset or replace the media element after our initial Play command.
        // Keep the actual element at 2x only for the duration of a silent analysis pass.
        for (const event of ["play", "ratechange"]) {
            document.addEventListener(event, event => state.applyAnalysisRate(event.target), true);
        }
    }
    if (typeof music.addEventListener === "function" && window.MusicKit?.Events?.playbackStateDidChange) {
        music.addEventListener(window.MusicKit.Events.playbackStateDidChange, event => {
            if (window.MusicKit.PlaybackStates?.completed !== undefined && event.state === window.MusicKit.PlaybackStates.completed) {
                state.completedID = String(music.nowPlayingItem?.id || state.lastID);
            }
        });
    }
}
const queueState = window.__musicPrayerQueueState;

const finite = value => Number.isFinite(value) ? Math.max(0, value) : 0;
switch (command) {
case "lyrics": {
    if (typeof value !== "string" || !/^\d+$/.test(value)) throw new Error("Invalid song ID");
    const response = await music.api.music("/v1/catalog/" + encodeURIComponent(music.storefrontId) + "/songs/" + value,
        { include: "syllable-lyrics,lyrics" });
    const catalog = response.data || {};
    const song = catalog.data?.[0];
    const related = [...(song?.relationships?.["syllable-lyrics"]?.data || []), ...(song?.relationships?.lyrics?.data || [])];
    const resources = [...related, ...(catalog.included || [])];
    const lyrics = ["syllable-lyrics", "lyrics"].map(type =>
        resources.find(item => item.type === type && typeof item.attributes?.ttml === "string" && item.attributes.ttml.length > 0)
    ).find(Boolean);
    return { songID: value, ttml: lyrics?.attributes?.ttml || null };
}
case "search": {
    if (typeof value !== "string" || !value.trim()) return { songs: [] };
    const response = await music.api.music("/v1/catalog/" + encodeURIComponent(music.storefrontId) + "/search",
        { term: value.trim(), types: "songs", limit: 25 });
    return { songs: (response.data?.results?.songs?.data || []).map(item => {
        const attributes = item.attributes || {};
        const artwork = attributes.artwork?.url;
        return {
            id: item.id, title: attributes.name || "", artist: attributes.artistName || "",
            album: attributes.albumName || "", duration: finite(attributes.durationInMillis) / 1000,
            artworkURL: typeof artwork === "string" ? artwork.replaceAll("{w}", "300").replaceAll("{h}", "300") : null
        };
    }) };
}
case "prepareSong":
case "playSong":
    if (typeof value !== "string" || !/^\d+$/.test(value)) throw new Error("Invalid song ID");
    queueState.completedID = null;
    queueState.lastID = value;
    music.shuffleMode = 0;
    music.repeatMode = 0;
    if (typeof music.autoplayEnabled === "boolean") music.autoplayEnabled = false;
    await music.setQueue({ song: value });
    if (typeof invocationIsCurrent === "function" && !invocationIsCurrent()) throw new Error("Selection expired");
    queueState.completedID = null;
    queueState.lastID = value;
    if (command === "playSong") await music.play(); else await music.pause();
    break;
case "analysisRate": {
    if (value !== 1 && value !== 2) throw new Error("Invalid analysis playback rate");
    queueState.analysisRate = value === 2 ? 2 : null;
    if ('playbackRate' in music) Reflect.set(music, 'playbackRate', value);
    const media = document.getElementById("apple-music-player");
    if (!media && value === 2) throw new Error("Analysis media is not ready");
    if (media) {
        media.preservesPitch = true;
        media.defaultPlaybackRate = value;
        media.playbackRate = value;
    }
    break;
}
case "toggle":
    if (music.isPlaying) await music.pause(); else { queueState.completedID = null; await music.play(); }
    break;
case "pause": await music.pause(); break;
case "stop": queueState.completedID = null; await music.stop(); break;
case "next":
    if (music.queue?.nextPlayableItem) await music.skipToNextItem();
    break;
case "previous":
    if (music.currentPlaybackTime > 3) await music.seekToTime(0);
    else if (music.queue?.previousPlayableItem) await music.skipToPreviousItem();
    break;
case "seek": queueState.completedID = null; await music.seekToTime(Math.min(finite(value), finite(music.currentPlaybackDuration))); break;
case "volume": music.volume = Math.min(1, finite(value)); break;
case "snapshot":
    if (queueState.analysisRate === 2) queueState.applyAnalysisRate(document.getElementById("apple-music-player"));
    if (Number.isFinite(value) && music.volume !== value) music.volume = Math.max(0, Math.min(1, value));
    break;
default: throw new Error("Unknown playback command");
}
const item = music.nowPlayingItem;
if (item?.id) queueState.lastID = String(item.id);
const attributes = item?.attributes;
const artwork = attributes?.artwork?.url;
// MusicKit's clock can be quantized to whole seconds. Use the actual media
// clock for continuous visual motion and lyric timing, including while paused.
const media = typeof document !== "undefined" ? document.getElementById?.("apple-music-player") : null;
const playbackTime = media && media.readyState >= 2 && Number.isFinite(media.currentTime)
    ? media.currentTime : music.currentPlaybackTime;
return {
    id: String(item?.id || queueState.completedID || ""),
    isReady: true,
    isAuthorized: !!music.isAuthorized,
    available: !!item,
    title: item?.title || attributes?.name || "",
    artist: item?.artistName || attributes?.artistName || "",
    artworkURL: typeof artwork === "string" ? artwork.replaceAll("{w}", "600").replaceAll("{h}", "600") : null,
    isPlaying: !!music.isPlaying,
    ended: queueState.completedID !== null || (window.MusicKit?.PlaybackStates?.completed !== undefined && music.playbackState === window.MusicKit.PlaybackStates.completed),
    time: finite(playbackTime),
    playbackRate: media ? media.playbackRate : null,
    preservesPitch: media ? media.preservesPitch : null,
    duration: finite(music.currentPlaybackDuration),
    canNext: !!music.queue?.nextPlayableItem,
    canPrevious: !!music.queue?.previousPlayableItem || finite(music.currentPlaybackTime) > 3
};

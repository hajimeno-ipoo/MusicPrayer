// Runs only in the official page. Authentication and audio stay in its existing player.
if (location.protocol !== "https:" || location.hostname !== "music.apple.com") return null;
let music;
try { music = window.MusicKit?.getInstance(); } catch { return null; }
if (!music) {
    if (command === "search" || command === "currentSong" || command === "playSong" || command === "prepareSong") throw new Error("Apple Music is not ready");
    return null;
}

const finite = value => Number.isFinite(value) ? Math.max(0, value) : 0;
const catalogSong = item => {
    const attributes = item.attributes || {};
    const artwork = attributes.artwork?.url;
    return {
        id: item.id, title: attributes.name || "", artist: attributes.artistName || "",
        album: attributes.albumName || "", duration: finite(attributes.durationInMillis) / 1000,
        artworkURL: typeof artwork === "string" ? artwork.replaceAll("{w}", "300").replaceAll("{h}", "300") : null
    };
};

// Reading the official browser never installs native queue listeners or writes player state.
const snapshot = (completedID, pendingSeek = null, selectedID = "") => {
    const item = music.nowPlayingItem;
    const attributes = item?.attributes;
    const artwork = attributes?.artwork?.url;
    // MusicKit's clock can be quantized to whole seconds. Use the actual media
    // clock for continuous visual motion and lyric timing, including while paused.
    const media = typeof document !== "undefined" ? document.getElementById?.("apple-music-player") : null;
    const playbackTime = media && media.readyState >= 2 && Number.isFinite(media.currentTime)
        ? media.currentTime : music.currentPlaybackTime;
    return {
        id: String(item?.id || completedID || selectedID || ""),
        isReady: true,
        isAuthorized: !!music.isAuthorized,
        available: !!item,
        title: item?.title || attributes?.name || "",
        artist: item?.artistName || attributes?.artistName || "",
        artworkURL: typeof artwork === "string" ? artwork.replaceAll("{w}", "600").replaceAll("{h}", "600") : null,
        isPlaying: !!music.isPlaying,
        ended: completedID !== null || (window.MusicKit?.PlaybackStates?.completed !== undefined && music.playbackState === window.MusicKit.PlaybackStates.completed),
        time: pendingSeek === null ? finite(playbackTime) : pendingSeek,
        playbackRate: media ? media.playbackRate : null,
        preservesPitch: media ? media.preservesPitch : null,
        duration: finite(music.currentPlaybackDuration),
        canNext: !!music.queue?.nextPlayableItem,
        canPrevious: !!music.queue?.previousPlayableItem || finite(music.currentPlaybackTime) > 3
    };

};
if (command === "browserSnapshot") return snapshot(null);

// Read the clicked song without touching the official player's queue or completion state.
if (command === "currentSong") {
    const item = music.nowPlayingItem;
    if (!item) return { songs: [] };
    const id = String(item.playParams?.catalogId || item.attributes?.playParams?.catalogId || item.id || "");
    if (!/^\d+$/.test(id)) throw new Error("The current item has no catalog song ID");
    const response = await music.api.music("/v1/catalog/" + encodeURIComponent(music.storefrontId) + "/songs/" + id);
    const song = response.data?.data?.find(song => song.type === "songs" && String(song.id) === id);
    if (!song?.attributes?.name || !Number.isFinite(song.attributes.durationInMillis) || song.attributes.durationInMillis <= 0) {
        throw new Error("The current song is unavailable in the catalog");
    }
    return { songs: [catalogSong(song)] };
}

switch (command) {
case "lyrics": {
    if (typeof value !== "string" || !/^\d+$/.test(value)) throw new Error("Invalid song ID");
    const response = await music.api.music("/v1/catalog/" + encodeURIComponent(music.storefrontId) + "/songs/" + value,
        { include: "syllable-lyrics,lyrics" });
    const catalog = response.data || {};
    const song = catalog.data?.find(item => String(item.id) === value);
    if (!song) throw new Error("The selected song is unavailable in the catalog");
    const related = [...(song?.relationships?.["syllable-lyrics"]?.data || []), ...(song?.relationships?.lyrics?.data || [])];
    const resources = [...related, ...(catalog.included || [])];
    const lyrics = ["syllable-lyrics", "lyrics"].map(type =>
        resources.find(item => item.type === type && typeof item.attributes?.ttml === "string" && item.attributes.ttml.length > 0)
    ).find(Boolean);
    return {
        songID: String(song.id),
        ttml: lyrics?.attributes?.ttml || null,
        hasLyrics: typeof song.attributes?.hasLyrics === "boolean" ? song.attributes.hasLyrics : null
    };
}
case "search": {
    if (typeof value !== "string" || !value.trim()) return { songs: [] };
    const response = await music.api.music("/v1/catalog/" + encodeURIComponent(music.storefrontId) + "/search",
        { term: value.trim(), types: "songs", limit: 25 });
    return { songs: (response.data?.results?.songs?.data || []).map(catalogSong) };
}
}

// The official page clears the current item after completion. Keep the completion event
// until the app advances its own queue instead of relying on a later polling sample.
if (!window.__musicPrayerQueueState || window.__musicPrayerQueueState.music !== music) {
    const state = { music, lastID: "", completedID: null, analysisRate: null, pendingSeek: null };
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
const applyPendingSeek = async () => {
    const duration = finite(music.currentPlaybackDuration);
    if (queueState.pendingSeek === null || duration <= 0) return;
    const target = Math.min(queueState.pendingSeek, duration);
    await music.seekToTime(target);
    queueState.pendingSeek = null;
};

switch (command) {
case "prepareSong":
case "playSong":
    if (typeof value !== "string" || !/^\d+$/.test(value)) throw new Error("Invalid song ID");
    if (command === "prepareSong" || queueState.lastID !== value) queueState.pendingSeek = null;
    queueState.completedID = null;
    queueState.lastID = value;
    music.shuffleMode = 0;
    music.repeatMode = 0;
    if (typeof music.autoplayEnabled === "boolean") music.autoplayEnabled = false;
    await music.setQueue({ song: value });
    if (typeof invocationIsCurrent === "function" && !invocationIsCurrent()) throw new Error("Selection expired");
    queueState.completedID = null;
    queueState.lastID = value;
    if (command === "playSong") { await music.play(); await applyPendingSeek(); }
    else await music.pause();
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
    if (music.isPlaying) await music.pause(); else { queueState.completedID = null; await music.play(); await applyPendingSeek(); }
    break;
case "pause": await music.pause(); break;
case "stop": queueState.completedID = null; queueState.pendingSeek = null; await music.stop(); break;
case "next":
    if (music.queue?.nextPlayableItem) await music.skipToNextItem();
    break;
case "previous":
    if (music.currentPlaybackTime > 3) await music.seekToTime(0);
    else if (music.queue?.previousPlayableItem) await music.skipToPreviousItem();
    break;
case "seek":
    queueState.completedID = null;
    queueState.pendingSeek = finite(value);
    await applyPendingSeek();
    break;
case "volume": music.volume = Math.min(1, finite(value)); break;
case "snapshot":
    if (music.isPlaying) await applyPendingSeek();
    if (queueState.analysisRate === 2) queueState.applyAnalysisRate(document.getElementById("apple-music-player"));
    break;
default: throw new Error("Unknown playback command");
}
const item = music.nowPlayingItem;
if (item?.id) queueState.lastID = String(item.id);
return snapshot(queueState.completedID, queueState.pendingSeek, queueState.lastID);

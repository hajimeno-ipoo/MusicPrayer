import WebKit

/// Keep the official palette, soften its base background and reuse its player material.
enum AppleMusicAppearance {
    // Keep this restricted to the displayed official browser, never login popups or workers.
    @MainActor static func configure(_ webView: WKWebView) {
        // macOS WKWebView has no public drawsBackground property; this disables only its backing fill.
        webView.setValue(false, forKey: "drawsBackground")
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: controlsScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    static let controlsScript = """
    (() => {
        if (location.hostname !== 'music.apple.com') return;
        const style = document.createElement('style');
        style.textContent = `
            html, body { background-color: transparent !important; }
            .app-container {
                background-color: color-mix(in srgb, var(--joe-color, var(--pageBG)) 80%, transparent);
            }
            .app-container .scrollable-page,
            .app-container .container-detail-header-wrapper::after,
            .app-container .library-track--header,
            .app-container .artist-detail-container {
                background-color: transparent !important;
            }
            .app-container .search-input__text-field,
            .app-container .search-scope-bar__pill-container {
                background-color: var(--glassMaterialBackground) !important;
                -webkit-backdrop-filter: var(--glassMaterialBackdropFilter, saturate(220%) blur(16px));
                backdrop-filter: var(--glassMaterialBackdropFilter, saturate(220%) blur(16px));
            }
            .app-container .search-input-wrapper,
            .app-container .search-scope-bar__pill-container {
                box-shadow: 0 10px 40px var(--glassMaterialShadowColor) !important;
            }
            .app-container.is-light-theme .search-input-wrapper,
            .app-container.is-light-theme .search-scope-bar__pill-container {
                --glassMaterialBackground: var(--glassMaterialBackground-onLight);
                --glassMaterialShadowColor: var(--glassMaterialShadowColor-onLight);
            }
            .app-container.is-dark-theme .search-input-wrapper,
            .app-container.is-dark-theme .search-scope-bar__pill-container {
                --glassMaterialBackground: var(--glassMaterialBackground-onDark);
                --glassMaterialShadowColor: var(--glassMaterialShadowColor-onDark);
            }
            amp-contextual-menu-button:has([data-testid="sort-menu-trigger"]) {
                --ctxmenu-trigger-background-color: transparent;
                --ctxmenu-trigger-backdrop-blur: 0px;
            }
            @media (min-width: 484px) {
                .app-container:not(.is-drawer-open) .player-bar__floating-player {
                    padding-inline-end: 168px !important;
                }
                .player-bar__floating-player .chrome-player {
                    margin-inline: auto 0 !important;
                }
            }
            .player-bar__floating-player .music-prayer-controls {
                position: absolute;
                top: 0;
                inset-inline-end: 20px;
                display: flex;
                gap: 4px;
                box-sizing: border-box;
                width: 132px;
                padding: 0 8px;
                margin: 0 !important;
                color: var(--systemPrimary);
            }
            .music-prayer-controls::after { inset-inline-start: 0; }
            .music-prayer-controls button {
                position: relative;
                z-index: calc(var(--z-default) + 1);
                display: grid;
                place-items: center;
                width: 36px;
                height: 36px;
                padding: 0;
                border: 0;
                background: transparent;
                color: inherit;
                cursor: pointer;
            }
            .music-prayer-controls button:disabled { opacity: .4; cursor: default; }
            .music-prayer-controls svg { width: 20px; height: 20px; }
            .music-prayer-add-notice {
                position: fixed !important;
                bottom: 96px;
                inset-inline-end: 20px;
                z-index: 9999;
                box-sizing: border-box;
                width: max-content;
                max-width: min(420px, calc(100vw - 40px));
                height: auto !important;
                min-height: 0 !important;
                padding: 16px 20px;
                margin: 0 !important;
                border-radius: 16px !important;
                color: var(--systemPrimary);
                font-size: 14px;
                line-height: 1.5;
                white-space: normal;
                overflow-wrap: anywhere;
                pointer-events: none;
            }
            .music-prayer-add-notice[hidden] { display: none !important; }
            .music-prayer-add-notice span { position: relative; z-index: 1; }
        `;
        document.head.appendChild(style);

        let controls;
        let notice;
        let noticeTimeout;
        let lastMessage = '';
        let state = { canGoBack: false, canAdd: false, isAdding: false, message: '' };
        const update = next => {
            state = next;
            if (!controls) return;
            controls.querySelector('[data-action="back"]').disabled = !state.canGoBack;
            const add = controls.querySelector('[data-action="add"]');
            add.disabled = !state.canAdd || state.isAdding;
            add.title = state.message || '再生中の曲を一覧に追加';
            add.setAttribute('aria-busy', String(state.isAdding));
            if (notice && state.message !== lastMessage) {
                lastMessage = state.message;
                clearTimeout(noticeTimeout);
                notice.querySelector('span').textContent = state.message;
                notice.hidden = !state.message;
                if (state.message) noticeTimeout = setTimeout(() => { notice.hidden = true; }, 4000);
            }
        };
        window.musicPrayerControls = { update };
        const mount = () => {
            const player = document.querySelector('.player-bar__floating-player .chrome-player:not(.music-prayer-controls)');
            if (!player || controls?.parentElement === player.parentElement) return;
            controls?.remove();
            controls = document.createElement('div');
            // The current official class supplies its theme, glass, inner stroke and height.
            controls.className = player.className + ' music-prayer-controls';
            controls.setAttribute('role', 'group');
            controls.setAttribute('aria-label', 'MusicPrayerの操作');
            const actions = [
                ['player', 'プレイヤーに戻る', '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m10 8 6 4-6 4Z" fill="currentColor" stroke="none"/>'],
                ['back', '前のページに戻る', '<path d="m12 5-7 7 7 7M5 12h15"/>'],
                ['add', '再生中の曲を一覧に追加', '<path d="M12 4v16M4 12h16"/>']
            ];
            for (const [action, label, path] of actions) {
                const button = document.createElement('button');
                button.type = 'button';
                button.dataset.action = action;
                button.title = label;
                button.setAttribute('aria-label', label);
                button.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + path + '</svg>';
                button.addEventListener('click', () => window.webkit?.messageHandlers?.musicPrayerControls?.postMessage(action));
                controls.appendChild(button);
            }
            player.parentElement.appendChild(controls);
            if (!notice?.isConnected) {
                notice = document.createElement('div');
                notice.className = player.className + ' music-prayer-add-notice';
                notice.hidden = true;
                notice.setAttribute('role', 'status');
                notice.setAttribute('aria-live', 'polite');
                notice.setAttribute('aria-atomic', 'true');
                notice.appendChild(document.createElement('span'));
                player.closest('.app-container').appendChild(notice);
            }
            update(state);
            window.webkit?.messageHandlers?.musicPrayerControls?.postMessage('ready');
        };
        new MutationObserver(mount).observe(document.body, {childList: true, subtree: true});
        mount();
    })();
    """
}

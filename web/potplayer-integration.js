// High-Speed PotPlayer Integration & Live Scrobbler for Jellyfin (Production Bridge)
(function() {
    console.log('[PotPlayer] Ultra-fast player & scrobbler bridge active.');

    function openPotPlayer(target, itemId) {
        if (!target) return;
        const apiClient = window.ApiClient;
        let payload = target;
        if (apiClient && itemId) {
            const userId = apiClient.getCurrentUserId() || '';
            const token = apiClient.accessToken() || '';
            const serverUrl = apiClient.serverAddress() || window.location.origin || '';
            payload = `${target}|${itemId}|${userId}|${token}|${serverUrl}`;
        }
        const encodedTarget = encodeURIComponent(payload);
        const potUri = 'potplayer://' + encodedTarget;

        let iframe = document.getElementById('potplayer-invoker');
        if (!iframe) {
            iframe = document.createElement('iframe');
            iframe.id = 'potplayer-invoker';
            iframe.style.display = 'none';
            document.body.appendChild(iframe);
        }
        iframe.src = potUri;
    }

    async function handlePlay(itemId, fallbackBtn) {
        try {
            const apiClient = window.ApiClient;
            if (!apiClient || !itemId) {
                if (fallbackBtn) fallbackBtn.click();
                return;
            }

            const item = await apiClient.getItem(apiClient.getCurrentUserId(), itemId);
            if (!item) {
                if (fallbackBtn) fallbackBtn.click();
                return;
            }

            // If it's a Series, find NextUp or First Episode
            if (item.Type === 'Series') {
                const nextUp = await apiClient.getNextUpEpisodes({ SeriesId: itemId, UserId: apiClient.getCurrentUserId() });
                if (nextUp && nextUp.Items && nextUp.Items.length > 0) {
                    return handlePlay(nextUp.Items[0].Id, fallbackBtn);
                }
                const eps = await apiClient.getEpisodes(itemId, { UserId: apiClient.getCurrentUserId(), Limit: 1 });
                if (eps && eps.Items && eps.Items.length > 0) {
                    return handlePlay(eps.Items[0].Id, fallbackBtn);
                }
            } else if (item.Type === 'Season') {
                const eps = await apiClient.getEpisodes(item.SeriesId, { SeasonId: itemId, UserId: apiClient.getCurrentUserId(), Limit: 1 });
                if (eps && eps.Items && eps.Items.length > 0) {
                    return handlePlay(eps.Items[0].Id, fallbackBtn);
                }
            }

            // Direct local file playback (fastest)
            if (item.Path && (item.Type === 'Episode' || item.Type === 'Movie')) {
                let localPath = item.Path;
                if (localPath.startsWith('R:\\') || localPath.startsWith('r:\\')) {
                    localPath = 'F:\\Media\\' + localPath.substring(3);
                }
                openPotPlayer(localPath, item.Id);
                return;
            }

            // Fallback direct HTTP stream
            const serverUrl = apiClient.serverAddress() || window.location.origin;
            const token = apiClient.accessToken();
            const streamUrl = `${serverUrl}/Videos/${itemId}/stream?static=true&api_key=${token}`;
            openPotPlayer(streamUrl, item.Id);
        } catch (err) {
            console.error('[PotPlayer] Error launching video:', err);
            if (fallbackBtn) fallbackBtn.click();
        }
    }

    function injectButtons() {
        // 1. Main detail page header play buttons
        const playButtons = document.querySelectorAll('.mainDetailButtons .btnPlay:not([data-potplayer-ready]), .detailButtons .btnPlay:not([data-potplayer-ready])');
        playButtons.forEach(btn => {
            btn.setAttribute('data-potplayer-ready', 'true');

            const potBtn = document.createElement('button');
            potBtn.className = 'raised emby-button emby-button-focusscale button-submit btnPotPlayer';
            potBtn.setAttribute('type', 'button');
            potBtn.style.marginLeft = '0.8em';
            potBtn.style.backgroundColor = '#E50914';
            potBtn.style.color = '#ffffff';
            potBtn.style.fontWeight = 'bold';
            potBtn.style.borderRadius = '6px';
            potBtn.style.padding = '0.6em 1.2em';
            potBtn.style.boxShadow = '0 4px 15px rgba(229, 9, 20, 0.4)';
            potBtn.innerHTML = '<span class="material-icons play_arrow" style="vertical-align:middle; margin-right:4px;"></span> <span>Play in PotPlayer</span>';

            potBtn.onclick = function(e) {
                e.preventDefault();
                e.stopPropagation();
                const view = document.querySelector('.itemDetailPage');
                const itemId = view ? view.getAttribute('data-itemid') || (window.location.hash.match(/id=([a-f0-9]+)/i) || [])[1] : null;
                handlePlay(itemId, btn);
            };

            if (btn.parentNode) {
                btn.parentNode.insertBefore(potBtn, btn.nextSibling);
            }
        });

        // 2. Per-Episode list items
        const listItems = document.querySelectorAll('.listItem');
        listItems.forEach(item => {
            const playStateBtn = item.querySelector('[data-itemtype="Episode"]');
            const itemId = item.getAttribute('data-itemid') || (playStateBtn ? playStateBtn.getAttribute('data-id') : null);
            const actionsContainer = item.querySelector('.listViewUserDataButtons');

            if (actionsContainer && itemId && !actionsContainer.querySelector('.btnPotPlayerEpisode')) {
                const epPotBtn = document.createElement('button');
                epPotBtn.className = 'listItemButton paper-icon-button-light emby-button btnPotPlayerEpisode';
                epPotBtn.setAttribute('type', 'button');
                epPotBtn.setAttribute('title', 'Play in PotPlayer');
                epPotBtn.style.color = '#E50914';
                epPotBtn.style.marginRight = '8px';
                epPotBtn.innerHTML = '<span class="material-icons play_circle_filled" style="color:#E50914; font-size:1.9em; vertical-align:middle; filter: drop-shadow(0 0 5px rgba(229,9,20,0.8));"></span>';

                epPotBtn.onclick = function(e) {
                    e.preventDefault();
                    e.stopPropagation();
                    handlePlay(itemId, null);
                };

                actionsContainer.insertBefore(epPotBtn, actionsContainer.firstChild);
            }
        });
    }

    setInterval(injectButtons, 400);
})();

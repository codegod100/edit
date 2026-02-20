// zagent Web UI
class ZagentApp {
    constructor() {
        this.lastSessionStorageKey = 'zagent_last_session_id';
        this.ws = null;
        this.connected = false;
        this.currentPath = null;
        this.currentFile = null;
        this.browserPath = null;
        this.fileContents = new Map();
        this.typingTimer = null;
        this.requestInFlight = false;
        this.requestTimeoutHandle = null;
        this.activeSessionId = null;
        this.pendingRestoreSessionId = this.loadLastSessionId();
        this.activeLogGroup = null;
        this.projectPathDirty = false;
        this.pendingProjectSet = false;
        
        this.init();
    }
    
    init() {
        this.cacheElements();
        this.bindEvents();
        this.connect();
    }
    
    cacheElements() {
        this.elements = {
            connectionStatus: document.getElementById('connectionStatus'),
            projectPathInput: document.getElementById('projectPathInput'),
            selectFolderBtn: document.getElementById('selectFolderBtn'),
            treeContent: document.getElementById('treeContent'),
            tabs: document.getElementById('tabs'),
            tabContent: document.getElementById('tabContent'),
            messages: document.getElementById('messages'),
            userInput: document.getElementById('userInput'),
            sendBtn: document.getElementById('sendBtn'),
            currentFile: document.getElementById('currentFile'),
            fileEditor: document.getElementById('fileEditor'),
            saveFileBtn: document.getElementById('saveFileBtn'),
            folderBrowser: document.getElementById('folderBrowser'),
            folderBrowserPath: document.getElementById('folderBrowserPath'),
            folderBrowserClose: document.getElementById('folderBrowserClose'),
            folderBrowserList: document.getElementById('folderBrowserList'),
            folderUpBtn: document.getElementById('folderUpBtn'),
            folderChooseBtn: document.getElementById('folderChooseBtn'),
            folderManualPathInput: document.getElementById('folderManualPathInput'),
            folderManualGoBtn: document.getElementById('folderManualGoBtn'),
            refreshSessionsBtn: document.getElementById('refreshSessionsBtn'),
            sessionsList: document.getElementById('sessionsList'),
        };
    }
    
    bindEvents() {
        // Tab switching
        this.elements.tabs.addEventListener('click', (e) => {
            const tab = e.target.closest('.tab');
            if (tab) {
                this.switchTab(tab.dataset.tab);
            }
        });
        
        // Project selection
        this.elements.selectFolderBtn.addEventListener('click', () => {
            this.selectFolder();
        });
        this.elements.folderBrowserClose.addEventListener('click', () => this.closeFolderBrowser());
        this.elements.folderUpBtn.addEventListener('click', () => {
            if (this.browserPath) {
                this.requestDirectoryList(this.browserPath + '/..');
            }
        });
        this.elements.folderChooseBtn.addEventListener('click', () => {
            if (!this.browserPath) return;
            this.elements.projectPathInput.value = this.browserPath;
            this.projectPathDirty = false;
            this.setProjectPath(this.browserPath);
            this.closeFolderBrowser();
        });
        this.elements.folderManualGoBtn.addEventListener('click', () => this.openManualFolderPath());
        this.elements.folderManualPathInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                this.openManualFolderPath();
            }
        });
        
        this.elements.projectPathInput.addEventListener('input', () => {
            this.projectPathDirty = true;
        });
        this.elements.projectPathInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                this.setProjectPath(this.elements.projectPathInput.value.trim());
            }
        });
        this.elements.refreshSessionsBtn.addEventListener('click', () => this.requestRecentSessions());
        
        // Chat input
        this.elements.userInput.addEventListener('input', () => {
            this.autoResizeTextarea(this.elements.userInput);
        });
        
        this.elements.userInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                this.sendMessage();
            }
        });
        
        this.elements.sendBtn.addEventListener('click', () => this.sendMessage());
        
        // File editor
        this.elements.saveFileBtn.addEventListener('click', () => this.saveCurrentFile());
        this.elements.fileEditor.addEventListener('input', () => {
            this.elements.saveFileBtn.disabled = false;
        });
    }
    
    connect() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}/ws`;
        
        this.ws = new WebSocket(wsUrl);
        
        this.ws.onopen = () => {
            this.connected = true;
            this.updateConnectionStatus('connected');
            this.elements.sendBtn.disabled = false;
            this.addSystemMessage('Connected to zagent');
            this.requestRecentSessions();
        };
        
        this.ws.onclose = () => {
            this.connected = false;
            this.updateConnectionStatus('disconnected');
            this.elements.sendBtn.disabled = true;
            this.clearPendingRequest();
            this.addSystemMessage('Disconnected from zagent');
            
            // Auto-reconnect after 3 seconds
            setTimeout(() => this.connect(), 3000);
        };
        
        this.ws.onerror = (error) => {
            console.error('WebSocket error:', error);
            this.updateConnectionStatus('error');
            this.clearPendingRequest();
        };
        
        this.ws.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                this.handleMessage(data);
            } catch (e) {
                console.error('Failed to parse message:', e);
                this.hideTypingIndicator();
                this.clearPendingRequest();
                this.addErrorMessage(`Client render error: ${e.message}`);
            }
        };
    }
    
    updateConnectionStatus(status) {
        this.elements.connectionStatus.className = `status-indicator ${status}`;
        const text = status === 'connected' ? 'Connected' : 
                     status === 'error' ? 'Error' : 'Connecting...';
        this.elements.connectionStatus.querySelector('.text').textContent = text;
    }
    
    switchTab(tabName) {
        // Update tab buttons
        this.elements.tabs.querySelectorAll('.tab').forEach(tab => {
            tab.classList.toggle('active', tab.dataset.tab === tabName);
        });
        
        // Update tab panes
        this.elements.tabContent.querySelectorAll('.tab-pane').forEach(pane => {
            pane.classList.toggle('active', pane.id === `${tabName}Pane`);
        });
    }
    
    selectFolder() {
        this.openFolderBrowser();
    }

    openFolderBrowser() {
        this.elements.folderBrowser.classList.remove('hidden');
        this.elements.folderManualPathInput.value = this.currentPath || this.elements.projectPathInput.value.trim() || '';
        const startPath = this.currentPath || this.elements.projectPathInput.value.trim() || '.';
        this.requestDirectoryList(startPath);
    }

    closeFolderBrowser() {
        this.elements.folderBrowser.classList.add('hidden');
    }

    openManualFolderPath() {
        const path = this.elements.folderManualPathInput.value.trim();
        if (!path) return;
        this.requestDirectoryList(path);
    }

    requestDirectoryList(path) {
        this.send({
            type: 'list_dir',
            path: path || '.'
        });
        this.elements.folderBrowserList.innerHTML = '<p class="empty-state">Loading directories...</p>';
    }
    
    setProjectPath(path) {
        this.pendingProjectSet = true;
        this.send({
            type: 'set_project',
            project_path: path
        });
    }
    
    sendMessage() {
        const content = this.elements.userInput.value.trim();
        if (!content || !this.connected) return;
        if (this.requestInFlight) {
            this.addSystemMessage('A request is already running. Wait for it to finish.');
            return;
        }
        
        // Add user message to UI
        this.addMessage('user', content);
        
        // Clear input
        this.elements.userInput.value = '';
        this.elements.userInput.style.height = 'auto';
        
        // Send to server
        this.send({
            type: 'user_input',
            content: content,
            project_path: this.currentPath
        });
        this.activeLogGroup = null;
        
        this.markRequestPending();

        // Show typing indicator
        this.showTypingIndicator();
    }
    
    send(data) {
        if (this.connected && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(data));
        }
    }
    
    handleMessage(data) {
        switch (data.type) {
            case 'assistant_output':
                if (data.kind) {
                    this.addAgentLog(data.kind, data.content || '');
                } else {
                    this.hideTypingIndicator();
                    this.clearPendingRequest();
                    const reasoning = typeof data.reasoning === 'string' ? data.reasoning.trim() : '';
                    const toolOutput = typeof data.tool_output === 'string' ? data.tool_output.trim() : '';
                    const commandOutput = typeof data.command_output === 'string' ? data.command_output.trim() : '';
                    const content = typeof data.content === 'string' ? data.content.trim() : '';
                    if (reasoning && !this.isDuplicateForKind('thinking', reasoning)) this.addAgentLog('thinking', reasoning);
                    if (toolOutput) this.addAgentLog('tool', toolOutput);
                    const normalizedEvent = this.normalizeEventLog(commandOutput);
                    if (normalizedEvent && !this.isDuplicateForKind('event', normalizedEvent)) this.addAgentLog('event', normalizedEvent);
                    if (content) this.addAgentLog('response', content);
                }
                break;

            case 'assistant_stream':
                this.addAgentLog(data.kind || 'event', data.content || '');
                break;
                
            case 'tool_call':
                this.addSystemMessage(`Tool: ${data.tool}`);
                break;
                
            case 'tool_result':
                this.addSystemMessage(`Result: ${data.tool}`);
                break;
                
            case 'file_list':
                this.renderFileTree(data.files);
                break;

            case 'recent_sessions':
                this.maybeRestoreLastSession(data.sessions || []);
                this.renderRecentSessions(data.sessions || []);
                break;

            case 'session_loaded':
                this.applyLoadedSession(data);
                break;

            case 'project_set':
                const canOverwritePathInput = this.pendingProjectSet || !this.projectPathDirty;
                if (canOverwritePathInput && typeof data.project_path === 'string' && data.project_path.trim()) {
                    this.currentPath = data.project_path;
                    this.elements.projectPathInput.value = data.project_path;
                    this.projectPathDirty = false;
                }
                this.pendingProjectSet = false;
                this.activeSessionId = null;
                this.clearLastSessionId();
                if (data.content) this.addSystemMessage(data.content);
                break;

            case 'session_title_updated':
                this.addSystemMessage('Session title updated.');
                this.requestRecentSessions();
                break;

            case 'dir_list':
                this.renderDirectoryList(data);
                break;
                
            case 'file_content':
                this.openFile(data.path, data.content);
                break;
                
            case 'file_saved':
                this.addSystemMessage(`Saved: ${data.path}`);
                this.elements.saveFileBtn.disabled = true;
                break;
                
            case 'error':
                this.hideTypingIndicator();
                this.clearPendingRequest();
                this.addErrorMessage(data.content);
                break;
                
            case 'status':
                this.addSystemMessage(data.content);
                break;
                
            default:
                console.log('Unknown message type:', data.type);
        }
    }

    requestRecentSessions() {
        this.send({ type: 'list_sessions' });
    }

    renderRecentSessions(sessions) {
        this.elements.sessionsList.innerHTML = '';
        if (!sessions || sessions.length === 0) {
            this.elements.sessionsList.innerHTML = '<p class="empty-state">No saved sessions yet</p>';
            return;
        }

        sessions.forEach((session) => {
            const item = document.createElement('div');
            item.className = 'session-entry';

            const title = session.title || session.id;
            const when = this.formatSessionTime(session.updated);
            const sessionPath = this.pathFromSession(session);
            const loadBtn = document.createElement('button');
            loadBtn.type = 'button';
            loadBtn.className = 'session-load';
            loadBtn.innerHTML = `
                <span class="session-title">${this.escapeHtml(title)}</span>
                <span class="session-meta">${this.escapeHtml(session.id)} · ${this.escapeHtml(when)}</span>
                ${sessionPath ? `<span class="session-path">${this.escapeHtml(sessionPath)}</span>` : ''}
            `;
            loadBtn.addEventListener('click', () => {
                const candidatePath = this.pathFromSession(session);
                if (candidatePath) {
                    this.currentPath = candidatePath;
                    this.elements.projectPathInput.value = candidatePath;
                }
                this.send({ type: 'load_session', session_id: session.id });
            });

            item.appendChild(loadBtn);
            if (session.id === this.activeSessionId) {
                const actions = document.createElement('div');
                actions.className = 'session-actions';
                const editBtn = document.createElement('button');
                editBtn.type = 'button';
                editBtn.className = 'session-edit';
                editBtn.textContent = 'Rename';
                editBtn.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.editSessionTitle(session);
                });
                actions.appendChild(editBtn);
                loadBtn.appendChild(actions);
            }
            this.elements.sessionsList.appendChild(item);
        });
    }

    editSessionTitle(session) {
        if (!session || !session.id) return;
        const currentTitle = (session.title || '').trim();
        const nextTitle = window.prompt('Edit session title', currentTitle);
        if (nextTitle === null) return;
        const trimmed = nextTitle.trim();
        if (!trimmed) {
            this.addErrorMessage('Session title cannot be empty.');
            return;
        }
        this.send({
            type: 'rename_session',
            session_id: session.id,
            title: trimmed,
        });
    }

    applyLoadedSession(data) {
        this.activeSessionId = data.session_id || null;
        this.saveLastSessionId(this.activeSessionId);
        this.requestRecentSessions();

        const turns = Array.isArray(data.turns) ? data.turns : [];
        this.elements.messages.innerHTML = '';
        turns.forEach((turn) => {
            const role = turn.role === 'assistant' ? 'assistant' : 'user';
            this.addMessage(role, turn.content || '');
        });
        if (turns.length === 0) {
            this.addSystemMessage('Loaded session has no messages.');
        }

        if (data.project_path) {
            this.currentPath = data.project_path;
            this.elements.projectPathInput.value = data.project_path;
            this.projectPathDirty = false;
        } else {
            const fallbackPath = this.pathFromSession(data);
            if (fallbackPath) {
                this.currentPath = fallbackPath;
                this.elements.projectPathInput.value = fallbackPath;
                this.projectPathDirty = false;
            }
        }

        this.hideTypingIndicator();
        this.clearPendingRequest();
        this.addSystemMessage(`Loaded session ${data.session_id || ''}`.trim());
    }

    maybeRestoreLastSession(sessions) {
        if (!this.pendingRestoreSessionId || !Array.isArray(sessions) || sessions.length === 0) return;
        const targetId = this.pendingRestoreSessionId;
        const found = sessions.find((s) => s && s.id === targetId);
        this.pendingRestoreSessionId = null;
        if (!found) {
            this.clearLastSessionId();
            return;
        }
        if (this.activeSessionId === targetId) return;
        const candidatePath = this.pathFromSession(found);
        if (candidatePath) {
            this.currentPath = candidatePath;
            this.elements.projectPathInput.value = candidatePath;
        }
        this.send({ type: 'load_session', session_id: targetId });
    }

    loadLastSessionId() {
        try {
            const value = window.localStorage.getItem(this.lastSessionStorageKey);
            return value && value.trim() ? value.trim() : null;
        } catch (_err) {
            return null;
        }
    }

    saveLastSessionId(sessionId) {
        try {
            if (sessionId && sessionId.trim()) {
                window.localStorage.setItem(this.lastSessionStorageKey, sessionId.trim());
            } else {
                window.localStorage.removeItem(this.lastSessionStorageKey);
            }
        } catch (_err) {}
    }

    clearLastSessionId() {
        this.pendingRestoreSessionId = null;
        this.saveLastSessionId(null);
    }

    formatSessionTime(rawValue) {
        const n = Number(rawValue);
        if (!Number.isFinite(n)) return 'unknown time';
        const ms = n > 1e12 ? Math.floor(n / 1e6) : n * 1000;
        const d = new Date(ms);
        if (Number.isNaN(d.getTime())) return 'unknown time';
        return d.toLocaleString();
    }

    pathFromSession(session) {
        if (!session) return null;
        const candidate = session.project_path || '';
        if (typeof candidate !== 'string') return null;
        const trimmed = candidate.trim();
        if (!trimmed.startsWith('/')) return null;
        return trimmed;
    }

    renderDirectoryList(data) {
        this.browserPath = data.path;
        this.elements.folderBrowserPath.textContent = data.path;
        this.elements.folderManualPathInput.value = data.path;
        this.elements.folderBrowserList.innerHTML = '';

        if (!data.entries || data.entries.length === 0) {
            this.elements.folderBrowserList.innerHTML = '<p class="empty-state">No subdirectories</p>';
            return;
        }

        data.entries.forEach((entry) => {
            const item = document.createElement('button');
            item.type = 'button';
            item.className = 'folder-entry';
            item.innerHTML = `<span class="icon">[dir]</span><span class="name">${entry.name}</span>`;
            item.addEventListener('click', () => this.requestDirectoryList(entry.path));
            this.elements.folderBrowserList.appendChild(item);
        });
    }
    
    addMessage(role, content) {
        const messageDiv = document.createElement('div');
        messageDiv.className = `message ${role}`;
        
        const contentDiv = document.createElement('div');
        contentDiv.className = 'message-content';
        contentDiv.innerHTML = this.formatMessage(content);
        
        messageDiv.appendChild(contentDiv);
        this.elements.messages.appendChild(messageDiv);
        this.scrollToBottom();
    }

    addAgentLog(kind, content) {
        const text = String(content || '').trim();
        if (!text) return;
        const label = this.agentLogLabel(kind);
        if (!label) return;

        const normalizedKind = String(kind || '').toLowerCase();
        const isResponse = normalizedKind === 'response';

        if (isResponse) {
            this.activeLogGroup = null;
            this.addMessage('assistant', `### ${label}\n${text}`);
            return;
        }

        if (this.activeLogGroup && this.activeLogGroup.kind === normalizedKind && this.activeLogGroup.contentNode) {
            this.activeLogGroup.body += `\n${text}`;
            const body = `### ${label}\n${this.activeLogGroup.body}`;
            this.activeLogGroup.contentNode.innerHTML = this.formatMessage(body);
            this.scrollToBottom();
            return;
        }

        const messageDiv = document.createElement('div');
        messageDiv.className = 'message assistant';
        const contentDiv = document.createElement('div');
        contentDiv.className = 'message-content';
        contentDiv.innerHTML = this.formatMessage(`### ${label}\n${text}`);
        messageDiv.appendChild(contentDiv);
        this.elements.messages.appendChild(messageDiv);
        this.scrollToBottom();

        this.activeLogGroup = {
            kind: normalizedKind,
            body: text,
            contentNode: contentDiv,
        };
    }

    normalizeEventLog(text) {
        const raw = String(text || '').trim();
        if (!raw) return '';
        if (raw.includes('--- Thinking ---')) return '';
        if (raw.includes('⛬ ')) return '';
        return raw;
    }

    isDuplicateForKind(kind, text) {
        if (!this.activeLogGroup) return false;
        if (this.activeLogGroup.kind !== String(kind || '').toLowerCase()) return false;
        const existing = String(this.activeLogGroup.body || '').trim();
        const incoming = String(text || '').trim();
        return existing === incoming || existing.includes(incoming) || incoming.includes(existing);
    }

    agentLogLabel(kind) {
        switch (String(kind || '').toLowerCase()) {
            case 'thinking':
                return 'Thinking';
            case 'tool':
                return 'Command Output';
            case 'status':
                return null;
            case 'response':
                return 'Response';
            default:
                return 'Event';
        }
    }
    
    addSystemMessage(content) {
        const messageDiv = document.createElement('div');
        messageDiv.className = 'message system';
        
        const contentDiv = document.createElement('div');
        contentDiv.className = 'message-content';
        contentDiv.textContent = content;
        
        messageDiv.appendChild(contentDiv);
        this.elements.messages.appendChild(messageDiv);
        this.scrollToBottom();
    }
    
    addErrorMessage(content) {
        const messageDiv = document.createElement('div');
        messageDiv.className = 'message error';
        
        const contentDiv = document.createElement('div');
        contentDiv.className = 'message-content';
        contentDiv.textContent = content;
        
        messageDiv.appendChild(contentDiv);
        this.elements.messages.appendChild(messageDiv);
        this.scrollToBottom();
    }
    
    formatMessage(content) {
        return this.renderMarkdown(content || '');
    }

    escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    sanitizeUrl(url) {
        const trimmed = (url || '').trim();
        if (!trimmed) return '#';
        if (/^(https?:\/\/|mailto:|\/)/i.test(trimmed)) return trimmed;
        return '#';
    }

    renderInlineMarkdown(text) {
        let out = text;
        out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
        out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, label, href) => {
            const safeHref = this.sanitizeUrl(href);
            return `<a href="${safeHref}" target="_blank" rel="noopener noreferrer">${label}</a>`;
        });
        out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
        out = out.replace(/\*([^*]+)\*/g, '<em>$1</em>');
        return out;
    }

    parseTableRow(line) {
        let value = line.trim();
        if (value.startsWith('|')) value = value.slice(1);
        if (value.endsWith('|')) value = value.slice(0, -1);
        return value.split('|').map((cell) => cell.trim());
    }

    isTableSeparator(line) {
        const cells = this.parseTableRow(line);
        if (cells.length === 0) return false;
        return cells.every((cell) => /^:?-{3,}:?$/.test(cell));
    }

    renderMarkdown(content) {
        const normalized = content.replace(/\r\n?/g, '\n');
        const codeBlocks = [];
        const withPlaceholders = normalized.replace(/```([a-zA-Z0-9_-]*)\n?([\s\S]*?)```/g, (_m, lang, code) => {
            const id = codeBlocks.length;
            const safeCode = this.escapeHtml(code);
            const langClass = lang ? ` language-${lang}` : '';
            codeBlocks.push(`<pre><code class="${langClass.trim()}">${safeCode}</code></pre>`);
            return `@@CODE_BLOCK_${id}@@`;
        });

        const escaped = this.escapeHtml(withPlaceholders);
        const lines = escaped.split('\n');
        const out = [];

        let inParagraph = false;
        let listType = null;

        const closeParagraph = () => {
            if (inParagraph) {
                out.push('</p>');
                inParagraph = false;
            }
        };

        const closeList = () => {
            if (listType) {
                out.push(listType === 'ol' ? '</ol>' : '</ul>');
                listType = null;
            }
        };

        for (let i = 0; i < lines.length; i += 1) {
            const line = lines[i];
            const trimmed = line.trim();

            const codeMatch = trimmed.match(/^@@CODE_BLOCK_(\d+)@@$/);
            if (codeMatch) {
                closeParagraph();
                closeList();
                out.push(codeBlocks[Number(codeMatch[1])] || '');
                continue;
            }

            if (!trimmed) {
                closeParagraph();
                closeList();
                continue;
            }

            const headingMatch = trimmed.match(/^(#{1,6})\s+(.*)$/);
            if (headingMatch) {
                closeParagraph();
                closeList();
                const level = headingMatch[1].length;
                out.push(`<h${level}>${this.renderInlineMarkdown(headingMatch[2])}</h${level}>`);
                continue;
            }

            const quoteMatch = trimmed.match(/^&gt;\s?(.*)$/);
            if (quoteMatch) {
                closeParagraph();
                closeList();
                out.push(`<blockquote>${this.renderInlineMarkdown(quoteMatch[1])}</blockquote>`);
                continue;
            }

            const nextLine = i + 1 < lines.length ? lines[i + 1].trim() : '';
            if (trimmed.includes('|') && nextLine && this.isTableSeparator(nextLine)) {
                closeParagraph();
                closeList();

                const headerCells = this.parseTableRow(trimmed);
                out.push('<table><thead><tr>');
                headerCells.forEach((cell) => {
                    out.push(`<th>${this.renderInlineMarkdown(cell)}</th>`);
                });
                out.push('</tr></thead><tbody>');

                i += 2; // Skip header separator row.
                while (i < lines.length) {
                    const rowLine = lines[i].trim();
                    if (!rowLine || !rowLine.includes('|')) break;
                    const rowCells = this.parseTableRow(rowLine);
                    if (this.isTableSeparator(rowLine)) {
                        i += 1;
                        continue;
                    }

                    out.push('<tr>');
                    rowCells.forEach((cell) => {
                        out.push(`<td>${this.renderInlineMarkdown(cell)}</td>`);
                    });
                    out.push('</tr>');
                    i += 1;
                }
                out.push('</tbody></table>');
                i -= 1;
                continue;
            }

            const olMatch = trimmed.match(/^\d+\.\s+(.*)$/);
            if (olMatch) {
                closeParagraph();
                if (listType !== 'ol') {
                    closeList();
                    out.push('<ol>');
                    listType = 'ol';
                }
                out.push(`<li>${this.renderInlineMarkdown(olMatch[1])}</li>`);
                continue;
            }

            const ulMatch = trimmed.match(/^[-*+]\s+(.*)$/);
            if (ulMatch) {
                closeParagraph();
                if (listType !== 'ul') {
                    closeList();
                    out.push('<ul>');
                    listType = 'ul';
                }
                out.push(`<li>${this.renderInlineMarkdown(ulMatch[1])}</li>`);
                continue;
            }

            closeList();
            if (!inParagraph) {
                out.push('<p>');
                inParagraph = true;
                out.push(this.renderInlineMarkdown(trimmed));
            } else {
                out.push('<br>');
                out.push(this.renderInlineMarkdown(trimmed));
            }
        }

        closeParagraph();
        closeList();

        return out.join('');
    }
    
    showTypingIndicator() {
        if (document.getElementById('typingIndicator')) return;
        
        const indicator = document.createElement('div');
        indicator.id = 'typingIndicator';
        indicator.className = 'message assistant';
        indicator.innerHTML = `
            <div class="message-content">
                <div class="typing-indicator">
                    <span></span>
                    <span></span>
                    <span></span>
                </div>
            </div>
        `;
        this.elements.messages.appendChild(indicator);
        this.scrollToBottom();
    }
    
    hideTypingIndicator() {
        const indicator = document.getElementById('typingIndicator');
        if (indicator) indicator.remove();
    }
    
    scrollToBottom() {
        this.elements.messages.scrollTop = this.elements.messages.scrollHeight;
    }
    
    renderFileTree(files) {
        this.elements.treeContent.innerHTML = '';
        
        if (!files || files.length === 0) {
            this.elements.treeContent.innerHTML = '<p class="empty-state">No files in this project</p>';
            return;
        }
        
        // Sort files
        const sorted = [...files].sort((a, b) => a.name.localeCompare(b.name));
        
        sorted.forEach(file => {
            const item = document.createElement('div');
            item.className = 'tree-item';
            item.dataset.path = file.path;
            
            const icon = this.getFileIcon(file.name);
            item.innerHTML = `
                <span class="icon">${icon}</span>
                <span class="name">${file.name}</span>
            `;
            
            item.addEventListener('click', () => {
                this.openFile(file.path);
                this.elements.treeContent.querySelectorAll('.tree-item').forEach(i => 
                    i.classList.remove('active')
                );
                item.classList.add('active');
            });
            
            this.elements.treeContent.appendChild(item);
        });
    }
    
    getFileIcon(filename) {
        const ext = filename.split('.').pop().toLowerCase();
        const icons = {
            js: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#f7df1e" stroke-width="2"><rect x="2" y="2" width="20" height="20" rx="2"/></svg>',
            ts: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#3178c6" stroke-width="2"><rect x="2" y="2" width="20" height="20" rx="2"/></svg>',
            html: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#e34c26" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>',
            css: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#264de4" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>',
            json: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#f7df1e" stroke-width="2"><rect x="2" y="2" width="20" height="20" rx="2"/></svg>',
            md: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#519aba" stroke-width="2"><rect x="2" y="2" width="20" height="20" rx="2"/></svg>',
            zig: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#f7a41d" stroke-width="2"><polygon points="12 2 2 22 22 22"/></svg>',
        };
        
        return icons[ext] || '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
    }
    
    openFile(path, content = null) {
        this.currentFile = path;
        this.elements.currentFile.textContent = path;
        
        if (content === null && this.fileContents.has(path)) {
            content = this.fileContents.get(path);
        }
        
        if (content !== null) {
            this.elements.fileEditor.value = content;
            this.elements.saveFileBtn.disabled = true;
            this.fileContents.set(path, content);
        } else {
            // Request file content from server
            this.send({
                type: 'read_file',
                path: path
            });
        }
        
        // Switch to editor tab
        this.switchTab('editor');
    }
    
    saveCurrentFile() {
        if (!this.currentFile) return;
        
        const content = this.elements.fileEditor.value;
        this.fileContents.set(this.currentFile, content);
        
        this.send({
            type: 'write_file',
            path: this.currentFile,
            content: content
        });
    }
    
    autoResizeTextarea(textarea) {
        textarea.style.height = 'auto';
        textarea.style.height = Math.min(textarea.scrollHeight, 200) + 'px';
    }

    markRequestPending() {
        this.requestInFlight = true;
        this.elements.sendBtn.disabled = true;
        if (this.requestTimeoutHandle) {
            clearTimeout(this.requestTimeoutHandle);
        }
        this.requestTimeoutHandle = setTimeout(() => {
            this.hideTypingIndicator();
            this.addErrorMessage('Request timed out after 90s. The server may still be busy; retry in a moment.');
            this.clearPendingRequest();
        }, 90000);
    }

    clearPendingRequest() {
        this.requestInFlight = false;
        if (this.requestTimeoutHandle) {
            clearTimeout(this.requestTimeoutHandle);
            this.requestTimeoutHandle = null;
        }
        this.elements.sendBtn.disabled = !this.connected;
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.zagentApp = new ZagentApp();
});

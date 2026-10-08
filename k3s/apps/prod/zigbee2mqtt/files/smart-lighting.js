const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const mqtt = require('mqtt');

const CACHE_FILE = path.join(__dirname, 'sl-cache.json');
const PUSHED_HASH_FILE = path.join(__dirname, 'sl-pushed-hash.json');
const CONFIG_TOPIC = 'zigbee2mqtt/sl/config';
const SNAP_TOPIC = 'zigbee2mqtt/sl/snap';
const STATUS_TOPIC = 'zigbee2mqtt/sl/status';
const BASE_TOPIC = 'zigbee2mqtt';

// Zigbee scene IDs: morning=1, day=2, evening=3, night=4
const WINDOW_SCENE_ID = { morning: 1, day: 2, evening: 3, night: 4 };
const WINDOWS = ['morning', 'day', 'evening', 'night'];

// Named custom scenes (per-room, captured live from each bulb's current state via
// the Scene Editor tab — see sl_save_custom_scene_lights.py). Automatically
// included in the Cycle Scenes rotation the moment they're named (see
// _cycleScenesForRoom) — no separate toggle to opt them in. Also individually
// recallable via the 'Scene: Custom N' button actions below.
//
// Unlike window scenes, a custom scene stores a DIFFERENT value per light in the
// room (roomConfig.custom_scenes[slot].lights[lightKey]) rather than one uniform
// room-wide value, so it can't be stored as a single Zigbee group scene and
// scene_recall'd atomically — see _applyCustomScene, which sends one direct
// command per light instead.
const CUSTOM_SLOTS = ['custom1', 'custom2', 'custom3'];
const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

// Button actions that directly recall one named custom-scene slot.
const CUSTOM_ACTION_SLOT = {
    'Scene: Custom 1': 'custom1',
    'Scene: Custom 2': 'custom2',
    'Scene: Custom 3': 'custom3',
};

// Stagger delay between Zigbee commands (ms) to avoid flooding
const CMD_STAGGER = 200;

// Maps Zigbee action string → button config key in switchConfig
const ACTION_TO_BTN = {
    'on_press_release':  'b1_short',
    'on_hold':           'b1_long',
    'up_press_release':  'b2_short',
    'up_hold':           'b2_long',
    'down_press_release':'b3_short',
    'down_hold':         'b3_long',
    'off_press_release': 'b4_short',
    'off_hold':          'b4_long',
};

// Default action per button when selector is 'Default' or unset. Same for
// every room — nothing room-specific or hardcoded here. If a room's custom
// scenes are all unnamed, 'Toggle All Rooms' just no-ops on nothing new;
// point a switch at 'Scene: Custom N' explicitly once you've saved one.
const BTN_DEFAULTS = {
    b1_short: 'Toggle Room',
    b1_long:  'Power Off All',
    b2_short: 'Brightness Up',
    b2_long:  'Brightness Max',
    b3_short: 'Brightness Down',
    b3_long:  'Brightness Min',
    b4_short: 'Cycle Scenes',
    b4_long:  'Toggle All Rooms',
};

class SmartLighting {
    constructor(zigbee, mqtt, state, publishEntityState, eventBus, enableDisableExtension, restartCallback, addExtension, settings, logger) {
        this.zigbee = zigbee;
        this.z2mMqtt = mqtt;
        this.state = state;
        this.eventBus = eventBus;
        this.settings = settings;
        this.logger = logger;
        this.config = null;
        this.configHash = null;
        this.lastSyncTime = null;
        this.currentWindow = null;
        this.checkInterval = null;
        this.cmdClient = null;
        /** @type {Record<string, 'ON'|'OFF'>} group/device state cache */
        this._deviceStateCache = Object.create(null);
        /** epoch ms before which device announces are ignored */
        this._smartPowerOnReadyAt = 0;
        /** last window applied per room via btn4 cycle */
        this._switchLastScene = Object.create(null);
    }

    async start() {
        this.logger.info('[SL] Smart Lighting extension starting');

        const mqttSettings = this.settings.get().mqtt;
        const brokerUrl = mqttSettings.server || 'mqtt://localhost:1883';
        this.cmdClient = mqtt.connect(brokerUrl, {
            clientId: 'z2m-smart-lighting-cmd',
            username: mqttSettings.user || undefined,
            password: mqttSettings.password || undefined,
        });

        this.logger.info(`[SL] Connecting cmdClient to ${brokerUrl}`);

        this.cmdClient.on('message', (topic, msg) => {
            // Bridge events: device announce
            if (topic === 'zigbee2mqtt/bridge/event') {
                try {
                    const ev = JSON.parse(msg.toString());
                    if (ev.type === 'device_announce') {
                        const fn = ev.data && ev.data.friendly_name;
                        if (fn) this._onDeviceAnnounce(fn);
                    }
                } catch { /* ignore */ }
                return;
            }

            const m = topic.match(/^zigbee2mqtt\/([^/]+)$/);
            if (!m) return;
            const deviceName = m[1];

            try {
                const parsed = JSON.parse(msg.toString());

                // Cache group/device ON/OFF state for _roomAnyOn() checks
                if (parsed.state === 'ON' || parsed.state === 'OFF') {
                    this._deviceStateCache[deviceName] = parsed.state;
                }

                // Handle switch button actions — no HA round-trip
                if (parsed.action && this.config && this.config.switches && this.config.switches[deviceName]) {
                    this._onSwitchAction(deviceName, this.config.switches[deviceName], parsed.action);
                }
            } catch { /* ignore non-JSON */ }
        });

        await new Promise((resolve, reject) => {
            this.cmdClient.on('connect', () => {
                this.logger.info('[SL] Command MQTT client connected');
                this.cmdClient.subscribe('zigbee2mqtt/+', err => {
                    if (err) this.logger.warn(`[SL] state-cache subscribe: ${err.message}`);
                    else this.logger.info('[SL] cmdClient subscribed for device/group state cache + switch actions');
                });
                this.cmdClient.subscribe('zigbee2mqtt/bridge/+', err => {
                    if (err) this.logger.warn(`[SL] bridge subscribe: ${err.message}`);
                    else this.logger.info('[SL] cmdClient subscribed to bridge events');
                });
                resolve();
            });
            this.cmdClient.on('error', (err) => {
                this.logger.error(`[SL] Command MQTT client error: ${err.message}`);
                reject(err);
            });
            setTimeout(() => reject(new Error('MQTT connect timeout')), 5000);
        });

        // Load cached config
        this.config = this._loadCache();
        if (this.config) {
            this.configHash = this._hashConfig(this.config);
            this.logger.info(`[SL] Loaded cached config from disk — hash=${this.configHash}`);
            this.currentWindow = this._calculateCurrentWindow();
            this.logger.info(`[SL] Current window: ${this.currentWindow}`);
        } else {
            this.logger.info('[SL] No cached config, waiting for HA');
        }

        await this.z2mMqtt.subscribe(CONFIG_TOPIC);
        this.logger.info(`[SL] Subscribed to ${CONFIG_TOPIC}`);

        await this.z2mMqtt.subscribe(SNAP_TOPIC);
        this.logger.info(`[SL] Subscribed to ${SNAP_TOPIC}`);

        this.eventBus.onMQTTMessage(this, this._onMQTTMessage.bind(this));

        // Ignore device announces during the first 60 s
        this._smartPowerOnReadyAt = Date.now() + 60000;

        this.checkInterval = setInterval(() => this._checkWindowTransition(), 30000);

        this._handleStartupPush();

        this._publishStatus('started');
    }

    async stop() {
        this.logger.info('[SL] Smart Lighting extension stopping');
        if (this.checkInterval) clearInterval(this.checkInterval);
        if (this.cmdClient) this.cmdClient.end();
        this.checkInterval = null;
        this.cmdClient = null;
        this.eventBus.removeListeners(this);
    }

    // ── Send command via external MQTT client ────────────────

    _sendCommand(topic, payload) {
        const fullTopic = `${BASE_TOPIC}/${topic}`;
        const message = typeof payload === 'string' ? payload : JSON.stringify(payload);
        if (this.cmdClient && this.cmdClient.connected) {
            this.cmdClient.publish(fullTopic, message);
        } else {
            this.logger.warn(`[SL] CMD client not connected, dropping: ${fullTopic}`);
        }
    }

    async _sendCommandsStaggered(commands) {
        for (let i = 0; i < commands.length; i++) {
            this._sendCommand(commands[i].topic, commands[i].payload);
            if (i < commands.length - 1) {
                await new Promise(r => setTimeout(r, CMD_STAGGER));
            }
        }
    }

    // ── Config from HA ───────────────────────────────────────

    _onMQTTMessage(data) {
        if (data.topic === CONFIG_TOPIC) {
            try {
                const newConfig = JSON.parse(data.message.toString());
                this.config = newConfig;
                this.configHash = this._hashConfig(newConfig);
                this._saveCache(newConfig);
                this.logger.info(`[SL] Config received — hash=${this.configHash} rooms=[${Object.keys(newConfig.rooms || {}).join(', ')}]`);
                this.currentWindow = this._calculateCurrentWindow();
                const pushedHash = this._loadPushedHash();
                if (this.configHash !== pushedHash) {
                    this.logger.info(`[SL] Config changed (${pushedHash ?? 'never'} → ${this.configHash}) — pushing scenes to bulbs`);
                    this._fullScenePush();
                } else {
                    this.logger.info(`[SL] Config unchanged (hash=${this.configHash}) — skipping scene push`);
                }
                this._publishStatus('config_updated');
            } catch (e) {
                this.logger.error(`[SL] Failed to parse config: ${e.message}`);
            }
            return;
        }

        if (data.topic === SNAP_TOPIC) {
            this._handleSnap(data.message.toString());
        }
    }

    _handleSnap(messageStr) {
        let parsed;
        try {
            parsed = JSON.parse(messageStr);
        } catch (e) {
            this.logger.error(`[SL] snap parse: ${e.message}`);
            return;
        }
        const roomKey = parsed && parsed.room_key;
        const window = parsed && parsed.window;
        if (!roomKey || !window) {
            this.logger.warn(`[SL] snap missing room_key/window: ${messageStr}`);
            return;
        }
        if (!WINDOWS.includes(window)) {
            this.logger.info(`[SL] snap ignored: window=${window} not standard`);
            return;
        }
        if (window !== this.currentWindow) {
            this.logger.info(`[SL] snap ignored: window=${window} != currentWindow=${this.currentWindow}`);
            return;
        }

        const ROOM_KEY_TO_GROUP = {
            living_room: 'Living Room', bedroom: 'Bedroom', bathroom: 'Bathroom',
            kitchen: 'Kitchen', hallway: 'Hallway',
        };
        const displayName = ROOM_KEY_TO_GROUP[roomKey];
        if (!displayName) {
            this.logger.warn(`[SL] snap unknown room_key: ${roomKey}`);
            return;
        }
        const roomConfig = this.config && this.config.rooms ? this.config.rooms[displayName] : null;
        if (!roomConfig) {
            this.logger.warn(`[SL] snap no roomConfig for ${displayName}`);
            return;
        }
        this.logger.info(`[SL] snap edit-recall: ${displayName} (${window})`);
        this._recallSceneIfOn(displayName, roomConfig, window);
    }

    // ── Startup scene push ───────────────────────────────────
    // Always called at startup regardless of hash. The config hash reflects HA
    // helper values only — a code change to scene_add format (e.g., adding
    // state: 'ON') doesn't change the hash, so skipping on hash-match would
    // leave bulbs with stale scenes that cannot turn lights on via scene_recall.
    _handleStartupPush() {
        if (!this.config || !this.currentWindow) return;
        this.logger.info(`[SL] Startup scene push — refreshing all scenes on bulbs (hash=${this.configHash})`);
        this._fullScenePush();
    }

    // ── Full scene push (config change) ─────────────────────
    // Stores ALL 4 scenes on every group so scene_recall works for any window.
    // Also updates hue_power_on_* on each bulb to the current-window scene values
    // so bulbs power on correctly even when the extension hasn't responded yet.
    // Does NOT scene_recall here (avoids visible snap-back after config push).

    async _fullScenePush() {
        if (!this.config || !this.config.rooms) return;

        this.logger.info(`[SL] Full scene push — storing all 4 scenes on all groups, current window: ${this.currentWindow}`);
        const commands = [];

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (!roomConfig.scenes) continue;

            for (const window of WINDOWS) {
                const scene = roomConfig.scenes[window];
                if (!scene) continue;

                const sceneAdd = {
                    ID: WINDOW_SCENE_ID[window],
                    name: window,
                    state: 'ON',
                    transition: 2,
                    brightness: scene.brightness,
                };
                if (scene.color) {
                    sceneAdd.color = scene.color;
                } else if (scene.color_temp !== undefined) {
                    sceneAdd.color_temp = scene.color_temp;
                }
                commands.push({ topic: `${roomName}/set`, payload: { scene_add: sceneAdd } });
            }

            // Custom scenes are NOT scene_add'd here — each one can hold a different
            // value per light, so there's no single group-wide Zigbee scene to store.
            // _applyCustomScene sends direct per-light commands at recall time instead.

            // For smart_power_on rooms: boot LED-off so the extension can turn it on
            // at exactly the right scene — zero flash. Non-smart rooms boot directly
            // at scene values since the extension won't fire for them on announce.
            const effectiveWindow = this._getEffectiveWindow(roomName);
            const currentScene = roomConfig.scenes && roomConfig.scenes[effectiveWindow];
            const smartPowerOn = roomConfig.smart_power_on !== false;
            if (currentScene) {
                for (const light of (roomConfig.lights || [])) {
                    commands.push({
                        topic: `${light}/set`,
                        payload: smartPowerOn
                            ? { hue_power_on_behavior: 'off' }
                            : {
                                hue_power_on_behavior: 'on',
                                hue_power_on_brightness: currentScene.brightness,
                                hue_power_on_color_temperature: currentScene.color_temp || 370,
                              }
                    });
                }
            }
        }

        this.logger.info(`[SL] Sending ${commands.length} commands (staggered ${CMD_STAGGER}ms)`);
        await this._sendCommandsStaggered(commands);

        this.lastSyncTime = new Date().toISOString();
        this._savePushedHash(this.configHash);
        this._publishStatus('synced');
    }

    // ── Window transition ────────────────────────────────────

    _checkWindowTransition() {
        if (!this.config) return;
        const newWindow = this._calculateCurrentWindow();
        if (newWindow && newWindow !== this.currentWindow) {
            this.logger.info(`[SL] Window transition: ${this.currentWindow} → ${newWindow}`);
            this.currentWindow = newWindow;
            this._onWindowTransition(newWindow);
        }
    }

    async _onWindowTransition(window) {
        if (!this.config || !this.config.rooms) return;

        this.logger.info(`[SL] Window transition → ${window}`);

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            const effectiveWindow = this._getEffectiveWindow(roomName);
            this._recallSceneIfOn(roomName, roomConfig, effectiveWindow);
        }

        this._publishStatus(`window_${window}`);
    }

    _recallSceneIfOn(roomName, roomConfig, window) {
        if (roomConfig.auto_transition === false) {
            this.logger.info(`[SL] Recall skipped for ${roomName} (auto_transition off)`);
            return;
        }
        if (!this._roomAnyOn(roomName)) return;
        const durationSecs = this._transitionDurationSecs(roomConfig);
        const payload = this._transition(roomName, window, roomConfig, durationSecs);
        if (!payload) return;
        this.logger.info(`[SL] Recalling ${window} scene on ${roomName} (lights on, transition=${durationSecs || 'instant'})`);
    }

    // ── Device announce (wall switch power-on) ───────────────

    _onDeviceAnnounce(friendlyName) {
        if (Date.now() < this._smartPowerOnReadyAt) return;
        if (!this.config || !this.config.rooms) return;
        if (this.config.sl_enabled === false) return;
        const hm = this.config.house_mode || 'Home';
        if (hm === 'Away') return;

        for (const [roomName, roomConfig] of Object.entries(this.config.rooms)) {
            if (!roomConfig.smart_power_on) continue;
            if (!(roomConfig.lights || []).includes(friendlyName)) continue;
            if (hm === 'Sleep' && !roomConfig.motion_night) {
                this.logger.info(`[SL] smart_power_on: ${friendlyName} skipped (Sleep, motion_night off)`);
                return;
            }
            const effectiveWindow = this._getEffectiveWindow(roomName);
            const scene = roomConfig.scenes && roomConfig.scenes[effectiveWindow];
            if (!scene) return;

            // hue_power_on_behavior is 'off' so the LED is dark until this fires.
            // transition:1 gives a clean 1 s fade-in — no flash, no pop.
            const cmd = { state: 'ON', brightness: scene.brightness, transition: 1 };
            if (scene.color) cmd.color = scene.color;
            else if (scene.color_temp !== undefined) cmd.color_temp = scene.color_temp;

            this.logger.info(`[SL] smart_power_on: ${friendlyName} announced → ${effectiveWindow} (${roomName})`);
            // 300 ms is enough for the Zigbee rejoin handshake; LED is dark the whole time.
            setTimeout(() => this._sendCommand(`${friendlyName}/set`, cmd), 300);
            return;
        }
    }

    // ── Button handling — replaces HA sl_switch_*.yaml automations ──

    _onSwitchAction(switchName, switchConfig, action) {
        if (!this.config) return;
        if (this.config.sl_enabled === false) return;

        const btnKey = ACTION_TO_BTN[action];
        if (!btnKey) {
            this.logger.debug(`[SL] switch ${switchName}: unhandled action ${action}`);
            return;
        }

        const configured = switchConfig[btnKey];
        const actionName = (!configured || configured === 'Default')
            ? BTN_DEFAULTS[btnKey]
            : configured;

        this.logger.info(`[SL] switch ${switchName}: ${action} → ${actionName} (room=${switchConfig.room_group})`);
        this._executeAction(actionName, switchConfig);
    }

    _executeAction(actionName, switchConfig) {
        const roomName = switchConfig.room_group;
        const brightStepPct = Number(switchConfig.brightness_step_pct) || 5;
        const minBrightPct = Number(switchConfig.min_brightness_pct) || 5;
        const brightStep = Math.round(brightStepPct / 100 * 254);
        const minBright = Math.max(1, Math.round(minBrightPct / 100 * 254));

        if (CUSTOM_ACTION_SLOT[actionName]) {
            this._recallCustomScene(roomName, CUSTOM_ACTION_SLOT[actionName]);
            return;
        }

        switch (actionName) {
            case 'Toggle Room':
                if (this._roomAnyOn(roomName)) {
                    this._sendCommand(`${roomName}/set`, { state: 'OFF' });
                    this._switchLastScene[roomName] = null;
                } else {
                    this._switchTurnRoomOn(roomName);
                }
                break;
            case 'Power Off Room':
                this._sendCommand(`${roomName}/set`, { state: 'OFF' });
                this._switchLastScene[roomName] = null;
                break;
            case 'Power Off All':
                this._allRoomsOff();
                break;
            case 'Brightness Up':
                this._sendCommand(`${roomName}/set`, { brightness_step: brightStep });
                break;
            case 'Brightness Max':
                this._sendCommand(`${roomName}/set`, { brightness: 254 });
                break;
            case 'Brightness Down':
                this._sendCommand(`${roomName}/set`, { brightness_step: -brightStep });
                break;
            case 'Brightness Min':
                this._sendCommand(`${roomName}/set`, { brightness: minBright });
                break;
            case 'Cycle Scenes':
                this._cycleScenesForRoom(roomName);
                break;
            case 'Toggle All Rooms':
                this._toggleAllRooms();
                break;
            case 'Multi-Room Scene':
                this._multiRoomOn(switchConfig);
                break;
            case 'Do Nothing':
                break;
            default:
                this.logger.warn(`[SL] unknown action name: ${actionName}`);
        }
    }

    _switchTurnRoomOn(roomName) {
        if (!this.config || !this.config.rooms) return;
        const hm = this.config.house_mode || 'Home';
        if (hm === 'Away') return;

        const roomConfig = this.config.rooms[roomName];
        if (!roomConfig) return;

        if (hm === 'Sleep' && !roomConfig.motion_night) return;

        const effectiveWindow = this._getEffectiveWindow(roomName);
        if (!roomConfig.scenes || !roomConfig.scenes[effectiveWindow]) return;

        // scene_recall is atomic — bulb transitions directly from off to the stored scene
        // without briefly flashing at its previous state (the direct-command path did: turn ON
        // at last state, then set color, causing a visible flicker on power-on).
        const sceneId = WINDOW_SCENE_ID[effectiveWindow];
        this._sendCommand(`${roomName}/set`, { scene_recall: sceneId });
        this._switchLastScene[roomName] = effectiveWindow;
    }

    _allRoomsOff() {
        if (!this.config || !this.config.rooms) return;
        for (const roomName of Object.keys(this.config.rooms)) {
            this._sendCommand(`${roomName}/set`, { state: 'OFF' });
            this._switchLastScene[roomName] = null;
        }
        this.logger.info('[SL] All rooms off');
    }

    // Cycle order is always the 4 windows followed by any named custom scene,
    // in slot order — derived fresh on every press directly from what
    // actually exists for the room. Naming a scene in the Scene Editor tab is
    // the only step needed to add it to rotation; clearing the name removes
    // it. No separate membership toggle to keep in sync.
    _cycleScenesForRoom(roomName) {
        if (!this.config || !this.config.rooms) return;
        const roomConfig = this.config.rooms[roomName];
        if (!roomConfig) return;

        const cycleList = [
            ...WINDOWS,
            ...CUSTOM_SLOTS.filter(slot =>
                roomConfig.custom_scenes && roomConfig.custom_scenes[slot] && roomConfig.custom_scenes[slot].name),
        ];

        const last = this._switchLastScene[roomName];
        const current = this.currentWindow || 'morning';
        const targetKey = (!last || !cycleList.includes(last))
            ? (cycleList.includes(current) ? current : cycleList[0])
            : cycleList[(cycleList.indexOf(last) + 1) % cycleList.length];

        if (CUSTOM_SLOTS.includes(targetKey)) {
            this._applyCustomScene(roomName, targetKey);
        } else {
            const sceneId = WINDOW_SCENE_ID[targetKey];
            if (!sceneId) return;
            this._sendCommand(`${roomName}/set`, { scene_recall: sceneId });
        }
        this._switchLastScene[roomName] = targetKey;
        this.logger.info(`[SL] cycle scene: ${roomName} → ${targetKey}`);
    }

    _toggleAllRooms() {
        if (!this.config || !this.config.rooms) return;
        const anyOn = Object.keys(this.config.rooms).some(r => this._roomAnyOn(r));
        if (anyOn) {
            this._allRoomsOff();
        } else {
            for (const roomName of Object.keys(this.config.rooms)) {
                this._switchTurnRoomOn(roomName);
            }
        }
    }

    // Recalls one named custom-scene slot directly (as opposed to Cycle
    // Scenes, which steps through all of them in order). No-ops with a
    // warning if the slot was never named — a button can be pointed at
    // 'Scene: Custom 2' before that scene exists yet.
    _recallCustomScene(roomName, slot) {
        if (!this._applyCustomScene(roomName, slot)) {
            this.logger.warn(`[SL] ${roomName}: ${slot} has no name configured, ignoring`);
            return;
        }
        this._switchLastScene[roomName] = slot;
    }

    // Applies a custom scene's per-light snapshot directly — one command per
    // light, each carrying that light's own state/brightness/color — rather
    // than a single Zigbee group scene_recall, since (unlike window scenes)
    // different lights in the same room can hold different values. Returns
    // false without sending anything if the slot has no name or no captured
    // lights yet.
    _applyCustomScene(roomName, slot) {
        if (!this.config || !this.config.rooms) return false;
        const roomConfig = this.config.rooms[roomName];
        const scene = roomConfig && roomConfig.custom_scenes && roomConfig.custom_scenes[slot];
        if (!scene || !scene.name || !scene.lights) return false;

        for (const [lightKey, entry] of Object.entries(scene.lights)) {
            let cmd;
            if (entry.state === 'OFF') {
                cmd = { state: 'OFF' };
            } else {
                cmd = { state: 'ON', brightness: entry.brightness };
                if (entry.color) cmd.color = entry.color;
                else if (entry.color_temp !== undefined) cmd.color_temp = entry.color_temp;
            }
            this._sendCommand(`${lightKey}/set`, cmd);
        }
        return true;
    }

    _multiRoomOn(switchConfig) {
        const groups = switchConfig.multi_room_groups || [];
        if (!groups.length) return;
        for (const roomName of groups) {
            this._switchTurnRoomOn(roomName);
        }
        this.logger.info(`[SL] multi-room on: [${groups.join(', ')}]`);
    }

    // ── Schedule calculation ─────────────────────────────────

    _calculateCurrentWindow() {
        if (!this.config || !this.config.profiles || !this.config.day_assignments) return null;
        const now = new Date();
        const dayName = DAY_NAMES[now.getDay()];
        const profileName = this.config.day_assignments[dayName] || 'weekday';
        const profile = this.config.profiles[profileName];
        if (!profile) return 'morning';
        const t = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
        if (t >= profile.night) return 'night';
        if (t >= profile.evening) return 'evening';
        if (t >= profile.day) return 'day';
        if (t >= profile.morning) return 'morning';
        return 'night';
    }

    _getEffectiveWindow(roomName) {
        if (!this.config || !this.config.profiles || !this.config.day_assignments) return this.currentWindow;
        const now = new Date();
        const dayName = DAY_NAMES[now.getDay()];
        const profileName = this.config.day_assignments[dayName] || 'weekday';
        const profile = { ...this.config.profiles[profileName] };
        const roomConfig = this.config.rooms[roomName];
        if (roomConfig && roomConfig.overrides) {
            for (const [w, time] of Object.entries(roomConfig.overrides)) {
                profile[w] = time;
            }
        }
        const t = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
        if (t >= profile.night) return 'night';
        if (t >= profile.evening) return 'evening';
        if (t >= profile.day) return 'day';
        if (t >= profile.morning) return 'morning';
        return 'night';
    }

    // ── Helpers ──────────────────────────────────────────────

    /** @returns {object | null} */
    _buildScenePayload(windowKey, roomConfig) {
        const scene = roomConfig.scenes && roomConfig.scenes[windowKey];
        if (!scene) return null;
        const cmd = { state: 'ON', brightness: scene.brightness };
        if (scene.color) cmd.color = scene.color;
        else if (scene.color_temp !== undefined) cmd.color_temp = scene.color_temp;
        return cmd;
    }

    _transitionDurationSecs(roomConfig) {
        const secs = Number(roomConfig.transition_secs);
        return secs > 0 ? secs : 0;
    }

    // ── Transition seam (backend contract §1a) ────────────────
    // The ONLY place that knows how a room fades from its current values to
    // a target scene. Swap this one function to change the mechanism (e.g. a
    // future stepped/eased curve engine sending intermediate commands on a
    // timer) without touching scheduling, mode gating, scene storage, or
    // button handling anywhere else. Today it delegates 100% to the bulb's
    // own firmware: one Zigbee command carrying a `transition` param, linear
    // interpolation done on-device.
    /** @returns {object | null} the payload sent, or null if no scene exists for windowKey */
    _transition(roomName, windowKey, roomConfig, durationSecs) {
        const payload = this._buildScenePayload(windowKey, roomConfig);
        if (!payload) return null;
        if (durationSecs > 0) payload.transition = durationSecs;
        this._sendCommand(`${roomName}/set`, payload);
        return payload;
    }

    // Individual bulbs first, group topic only as a fallback — 2026-08-23.
    // The room/group topic (e.g. "Kitchen") is fed by our OWN outgoing group
    // commands, which Z2M echoes back optimistically without waiting for any
    // bulb to actually acknowledge (Zigbee group addressing has no per-member
    // ack). If a bulb has no power, that echo still says "ON", and everything
    // downstream — this cache, the dashboard, the next button press — believes
    // a dark room is lit. Individual bulb topics only update from the bulb's
    // own real status reports, so they stay correct through exactly this
    // failure. Real incident: kitchen bulbs lost power, the group topic said
    // ON on the very first press, and every press after that alternated
    // between two commands that could never reach an unpowered bulb.
    _roomAnyOn(roomDisplayName) {
        const roomConfig = this.config && this.config.rooms ? this.config.rooms[roomDisplayName] : null;
        if (roomConfig && roomConfig.lights && roomConfig.lights.length > 0) {
            const known = roomConfig.lights.filter(l => this._deviceStateCache[l] !== undefined);
            if (known.length > 0) {
                return known.some(l => this._deviceStateCache[l] === 'ON');
            }
        }
        if (this._deviceStateCache[roomDisplayName] !== undefined) {
            return this._deviceStateCache[roomDisplayName] === 'ON';
        }
        return false;
    }

    _loadCache() {
        try { return JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8')); }
        catch { return null; }
    }

    _saveCache(config) {
        try { fs.writeFileSync(CACHE_FILE, JSON.stringify(config, null, 2)); }
        catch (e) { this.logger.error(`[SL] Failed to save cache: ${e.message}`); }
    }

    _hashConfig(config) {
        return crypto.createHash('sha256').update(JSON.stringify(config)).digest('hex').substring(0, 12);
    }

    _loadPushedHash() {
        try { return JSON.parse(fs.readFileSync(PUSHED_HASH_FILE, 'utf8')).hash || null; }
        catch { return null; }
    }

    _savePushedHash(hash) {
        try { fs.writeFileSync(PUSHED_HASH_FILE, JSON.stringify({ hash, pushedAt: new Date().toISOString() })); }
        catch (e) { this.logger.error(`[SL] Failed to save pushed hash: ${e.message}`); }
    }

    _publishStatus(status) {
        const payload = JSON.stringify({
            status,
            current_window: this.currentWindow,
            has_config: !!this.config,
            config_hash: this.configHash,
            last_sync: this.lastSyncTime,
            timestamp: new Date().toISOString(),
        });
        if (this.cmdClient && this.cmdClient.connected) {
            this.cmdClient.publish(STATUS_TOPIC, payload, { retain: true });
        }
    }
}

module.exports = SmartLighting;

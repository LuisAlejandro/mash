// The image-popup Fresh plugin: which hooks it listens to, and what it does
// when the pane cannot be opened.
//
// The failure this pins: a file-explorer browse opens the file as an ephemeral
// preview, and Fresh withholds `after_file_open` until the preview is escalated
// (file_open_orchestrators.rs, OpenKind::Preview). A plugin listening only to
// that hook therefore left the [BIN] hex dump on screen with no popup.
import assert from "node:assert/strict";
import { test } from "node:test";

const pluginUrl = new URL(
	"../defaults/fresh/plugins/packages/mash-image-popup/plugin.ts",
	import.meta.url,
);

// The plugin registers its handler once, at module load, through the global
// `registerHandler` Fresh provides. Each test swaps the `editor` it talks to.
const handlers = new Map();
const events = [];
globalThis.registerHandler = (name, fn) => handlers.set(name, fn);
globalThis.editor = { on: (event) => events.push(event) };

await import(pluginUrl.href);

function useEditor(options = {}) {
	const state = {
		spawns: [],
		closed: [],
		flushed: 0,
		buffer: { path: "/tmp/picture.png", is_virtual: false, ...options.buffer },
		spawnResult: { stdout: "", stderr: "", exit_code: 0, ...options.spawnResult },
	};
	globalThis.editor = {
		on: () => {},
		getEnv: (name) => (name === "HERDR_PANE_ID" ? "w1:p1" : undefined),
		getCwd: () => "/tmp",
		getBufferInfo: () => state.buffer,
		closeBuffer: (id) => state.closed.push(id),
		flush: () => {
			state.flushed += 1;
		},
		spawnProcess: (command, args) => {
			state.spawns.push([command, args]);
			return Promise.resolve(state.spawnResult);
		},
	};
	return state;
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 25));

const opened = {
	stdout: JSON.stringify({ type: "plugin_pane_opened" }),
	stderr: "",
	exit_code: 0,
};

test("listens to the preview hook as well as the deliberate-open hook", () => {
	assert.ok(events.includes("after_file_open"));
	assert.ok(
		events.includes("buffer_activated"),
		"buffer_activated is the only hook that fires for a file-explorer preview",
	);
});

test("a previewed image opens the pane and then drops the hex buffer", async () => {
	const state = useEditor({ spawnResult: opened });
	handlers.get("mashImagePopupOpen")({ buffer_id: 11, path: "/tmp/picture.png" });
	await settle();

	assert.equal(state.spawns.length, 1);
	const [command, args] = state.spawns[0];
	assert.equal(command, "herdr");
	assert.deepEqual(args.slice(0, 6), [
		"plugin",
		"pane",
		"open",
		"--plugin",
		"image-popup",
		"--entrypoint",
	]);
	assert.ok(args.includes("IMAGE_POPUP_FILE=/tmp/picture.png"));
	assert.deepEqual(state.closed, [11]);
});

test("herdr's JSON error leaves the file on screen", async () => {
	const state = useEditor({
		spawnResult: { stdout: '{"error":{"code":"plugin_not_found"}}', stderr: "", exit_code: 0 },
	});
	handlers.get("mashImagePopupOpen")({ buffer_id: 12, path: "/tmp/picture.png" });
	await settle();

	assert.equal(state.spawns.length, 1);
	assert.deepEqual(state.closed, [], "a failed open must not close the buffer");
});

test("the same buffer does not bounce twice", async () => {
	const state = useEditor({ spawnResult: opened });
	handlers.get("mashImagePopupOpen")({ buffer_id: 13, path: "/tmp/picture.png" });
	handlers.get("mashImagePopupOpen")({ buffer_id: 13, path: "/tmp/picture.png" });
	await settle();
	assert.equal(state.spawns.length, 1);
});

test("non-image files and virtual buffers are ignored", async () => {
	const state = useEditor({ buffer: { path: "/tmp/notes.md" } });
	handlers.get("mashImagePopupOpen")({ buffer_id: 14, path: "/tmp/notes.md" });
	await settle();
	assert.equal(state.spawns.length, 0);
	assert.deepEqual(state.closed, []);
});

/**
 * Mash Image Popup
 *
 * When an image file is opened in Fresh — from the file explorer, the quick
 * opener, a goto, anywhere — close the buffer and show the picture in a Herdr
 * popup with real pixels instead.
 *
 * Why this exists: Fresh is a text editor. A PNG opened in it is read back as
 * bytes (`<89>PNG<0D>…`), which is not a picture. A Herdr plugin pane is an
 * ordinary terminal pane, so a program in it can emit the Kitty graphics
 * protocol and the terminal draws the actual image. Fresh plugins cannot do
 * that: a plugin may only write text and colours into a buffer, and Kitty /
 * Sixel / iTerm sequences do not pass through Fresh's text-buffer API.
 *
 * The handoff is one command:
 *   herdr plugin pane open --plugin image-popup --entrypoint view \
 *     --placement split --target-pane <this pane> --direction right \
 *     --env IMAGE_POPUP_FILE=<file>
 *
 * `--placement split` rather than `popup` on purpose: a popup is a CLIENT-side
 * surface, rendered by the terminal window, and only a keybinding can open one
 * -- `plugin pane open --placement popup` from a helper returns ok and draws
 * nothing, and a plugin action runs its command without opening a manifest
 * pane. A split is server-side and works from anywhere.
 *
 * `--direction right` is a VERTICAL split: the image lands beside the editor,
 * not under it. `down` would stack them.
 *
 * The buffer is closed only after the popup is on its way, so a failure never
 * costs the user the file.
 */

const IMAGE_EXTENSIONS = [
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "avif", "svg",
];

/** Buffers already handed to the popup, so the two hooks do not open it twice. */
const handled = new Set<number>();

function isImagePath(path: string): boolean {
	if (!path) return false;
	const name = path.toLowerCase();
	const dot = name.lastIndexOf(".");
	if (dot < 0) return false;
	return IMAGE_EXTENSIONS.includes(name.slice(dot + 1));
}

/**
 * Ask Herdr which pane runs this Fresh instance. The editor's pid is in
 * `FRESH_SESSION` (`local-<pid>-<hash>`), and Herdr names a pane by its
 * foreground process, so the pane whose process tree contains that pid is the
 * one to split from. Falls back to the pane Herdr set on the process, which is
 * correct for the common case of a Fresh started inside a pane.
 */
async function findSelfPane(): Promise<string | null> {
	const own = editor.getEnv("HERDR_PANE_ID");
	const session = editor.getEnv("FRESH_SESSION") || "";
	const match = /local-(\d+)-/.exec(session);
	const herdrBin = editor.getEnv("HERDR_BIN_PATH") || "herdr";

	if (match) {
		try {
			// spawnProcess resolves to its own result: awaiting twice would read
			// `.result` off a SpawnResult and throw.
			const listing = await editor.spawnProcess(herdrBin, ["pane", "list"], editor.getCwd());
			const text = listing.stdout || "";
			const wanted = match[1];
			// Each pane row carries its pane id and its process tree. A pane whose
			// process list names this editor's pid is the one we are running in.
			const blocks = text.split(/\n(?=\s*\{)/);
			for (const block of blocks) {
				if (block.includes(`"pid":${wanted}`) || block.includes(`"pid": ${wanted}`)) {
					const id = /"pane_id":"([^"]+)"/.exec(block);
					if (id) return id[1];
				}
			}
		} catch {
			// Fall through to the environment hint below.
		}
	}
	return own || null;
}

async function openInPopup(path: string): Promise<boolean> {
	const selfPane = await findSelfPane();
	if (!selfPane) return false;

	const herdrBin = editor.getEnv("HERDR_BIN_PATH") || "herdr";
	try {
		const result = await editor.spawnProcess(herdrBin, [
			"plugin", "pane", "open",
			"--plugin", "image-popup",
			"--entrypoint", "view",
			"--placement", "split",
			"--target-pane", selfPane,
			"--direction", "right",
			"--env", `IMAGE_POPUP_FILE=${path}`,
			"--focus",
		], editor.getCwd());
		return result.exit_code === 0 && !/"error"/.test(result.stdout || "");
	} catch {
		return false;
	}
}

async function maybeShow(args: any): Promise<void> {
	const bufferId = args && typeof args.buffer_id === "number" ? args.buffer_id : null;
	if (bufferId === null || handled.has(bufferId)) return;

	const info = editor.getBufferInfo(bufferId);
	if (!info || info.is_virtual || !info.path) return;
	if (!isImagePath(info.path)) return;

	handled.add(bufferId);
	// Fire the popup request without awaiting the round-trip: the hook does not
	// await this handler, so anything after an `await` runs too late to affect
	// the buffer the user is looking at. The hex buffer is dropped only once
	// the pane is really there -- a failure leaves the file on screen, and on
	// disk, instead of silently taking the view away.
	void openInPopup(info.path)
		.then(function (opened) {
			if (!opened) {
				handled.delete(bufferId);
				return;
			}
			editor.closeBuffer(bufferId, true);
			void editor.flush();
		})
		.catch(function () {
			handled.delete(bufferId);
		});
}

registerHandler("mashImagePopupOpen", (args: any) => maybeShow(args));

// Both hooks, one popup. `after_file_open` fires for a deliberate open (the
// quick opener, `fresh <file>`, a goto). It does NOT fire for a file-explorer
// browse: that opens the file as an ephemeral preview and withholds the hook
// until the preview is escalated (file_open_orchestrators.rs, OpenKind) --
// which is why clicking a PNG in the explorer used to leave the hex dump on
// screen with no popup. `buffer_activated` still fires for the preview, so it
// covers that case; the buffer-id guard above is what keeps the two from
// opening the picture twice.
editor.on("after_file_open", "mashImagePopupOpen");
editor.on("buffer_activated", "mashImagePopupOpen");

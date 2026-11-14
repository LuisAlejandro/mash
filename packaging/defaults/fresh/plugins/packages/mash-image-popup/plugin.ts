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
 *     --placement popup --target-pane <this pane> \
 *     --width 40% --height 40% --env IMAGE_POPUP_FILE=<file>
 *
 * `--placement popup` rather than a split: the picture covers the editor for a
 * moment instead of rearranging the layout. 40% of the window is a glanceable
 * preview -- big enough to recognise the picture, small enough to leave the
 * text around it visible -- and herdr has no way to place a popup anywhere but
 * centred, so size is the only geometry lever there is. A popup is a
 * CLIENT-side surface, drawn by the attached terminal window; Mash has exactly
 * one attached client, so the no-client case -- the only one ever observed to
 * return ok and draw nothing -- cannot arise here.
 * `packaging/helpers/mash-update-notice` opens its popups from a background
 * launch helper the same way.
 *
 * `--width`/`--height` are the popup's OUTER cells (border included) and are
 * passed explicitly rather than left to the manifest's own `[[panes]]` entry, so
 * the geometry does not depend on which copy of the manifest is installed.
 * `--target-pane` keeps the popup over the editor instead of whichever pane
 * happens to be active.
 *
 * The buffer is closed only after the popup is on its way, so a failure never
 * costs the user the file.
 */

/**
 * Raster formats the pinned `viu` (1.6.1) actually decodes. Everything else
 * that merely LOOKS like an image is deliberately absent, because each one
 * fails inside the popup with a decoder error instead of a picture:
 *
 *   svg       XML. viu has no SVG support at all, and the hex buffer Fresh
 *             replaced was the readable source -- so leave the buffer alone.
 *   avif      the shipped viu is built without an AVIF decoder
 *             (`Unsupported(Exact(Avif))`).
 *   heic/jxl  no decoder (`Unsupported(PathExtension(...))`).
 *
 * Re-add a format only after probing the bundled viu for it.
 */
const IMAGE_EXTENSIONS = [
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico",
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
			// The handle resolves to its own result: awaiting twice would read
			// `.result` off a SpawnResult and throw.
			const listing = await editor.spawnHostProcess(herdrBin, ["pane", "list"], editor.getCwd());
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
		const result = await editor.spawnHostProcess(herdrBin, [
			"plugin", "pane", "open",
			"--plugin", "image-popup",
			"--entrypoint", "view",
			"--placement", "popup",
			"--target-pane", selfPane,
			"--width", "40%",
			"--height", "40%",
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

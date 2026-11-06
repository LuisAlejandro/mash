import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function languageName(value: string | undefined): string | undefined {
	if (!value?.trim()) return undefined;

	try {
		const locale = new Intl.Locale(value.trim());
		if (locale.language === "en") return undefined;
		const name = new Intl.DisplayNames(["en"], { type: "language" }).of(locale.toString());
		return name && name.toLowerCase() !== locale.toString().toLowerCase() ? name : undefined;
	} catch {
		return undefined;
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", (event) => {
		const language = languageName(process.env.MASH_LANGUAGE);
		if (!language) return;

		const guideline =
			`Reply to the user in ${language}. Keep code, identifiers, commit messages, and file contents ` +
			"in whatever language the project or user uses.";
		const guidelines = event.systemPromptOptions.promptGuidelines;
		if (!guidelines.includes(guideline)) guidelines.push(guideline);
	});
}

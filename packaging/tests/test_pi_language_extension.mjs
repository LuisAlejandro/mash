import assert from "node:assert/strict";

const previousLanguage = process.env.MASH_LANGUAGE;
try {
  const { default: register } = await import(
    new URL("../defaults/pi/extensions/mash-language.ts", import.meta.url)
  );
  let beforeAgentStart;
  register({
    on(event, handler) {
      assert.equal(event, "before_agent_start");
      beforeAgentStart = handler;
    },
  });
  assert.equal(typeof beforeAgentStart, "function");

  const makeOptions = () => ({
    promptGuidelines: ["Existing guideline."],
    sections: { project_context: "Project instructions" },
  });

  process.env.MASH_LANGUAGE = "es";
  const spanish = makeOptions();
  await beforeAgentStart({ systemPromptOptions: spanish });
  const spanishGuideline =
    "Reply to the user in Spanish. Keep code, identifiers, commit messages, and file contents " +
    "in whatever language the project or user uses.";
  assert.equal(spanish.promptGuidelines.filter((item) => item === spanishGuideline).length, 1);
  assert.deepEqual(spanish.sections, { project_context: "Project instructions" });
  assert.equal(spanish.promptGuidelines[0], "Existing guideline.");

  // Repeated turns retain other prompt content and do not append a duplicate.
  await beforeAgentStart({ systemPromptOptions: spanish });
  assert.equal(spanish.promptGuidelines.filter((item) => item === spanishGuideline).length, 1);
  const secondTurn = makeOptions();
  await beforeAgentStart({ systemPromptOptions: secondTurn });
  assert.deepEqual(secondTurn.promptGuidelines, ["Existing guideline.", spanishGuideline]);
  assert.deepEqual(secondTurn.sections, { project_context: "Project instructions" });

  for (const language of ["en", undefined]) {
    if (language === undefined) delete process.env.MASH_LANGUAGE;
    else process.env.MASH_LANGUAGE = language;
    const options = makeOptions();
    const original = structuredClone(options);
    await beforeAgentStart({ systemPromptOptions: options });
    assert.deepEqual(options, original, `prompt changed for MASH_LANGUAGE=${language ?? "unset"}`);
  }

  process.env.MASH_LANGUAGE = "not a locale!";
  const invalid = makeOptions();
  const original = structuredClone(invalid);
  await beforeAgentStart({ systemPromptOptions: invalid });
  assert.deepEqual(invalid, original, "prompt changed for an invalid locale");

  console.log("Pi language extension: ok");
} finally {
  if (previousLanguage === undefined) delete process.env.MASH_LANGUAGE;
  else process.env.MASH_LANGUAGE = previousLanguage;
}

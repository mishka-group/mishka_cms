import { describe, expect, it } from "vitest";
import { mentionAt, withMention } from "./pb_mention";

describe("mentionAt", () => {
  it("finds a name being written at the caret", () => {
    expect(mentionAt("ping @sa", 8)).toEqual({ query: "sa", at: 5 });
  });

  it("finds one at the very start of the note", () => {
    expect(mentionAt("@sa", 3)).toEqual({ query: "sa", at: 0 });
  });

  // Pressing `@` with nothing after it is still a name being written — that is when the list should
  // open, before there is anything to filter by.
  it("an empty name is a name being written", () => {
    expect(mentionAt("ping @", 6)).toEqual({ query: "", at: 5 });
  });

  // THE CASE THE ANCHOR EXISTS FOR. The `@` in a quoted address has a letter in front of it.
  it("a quoted address is not a name", () => {
    expect(mentionAt("write to sara@example", 21)).toBeNull();
  });

  // The picker writes whole addresses, so the second `@` is part of what is being typed — the list
  // has to stay open through it, or naming somebody by domain is impossible.
  it("keeps reading through the address's own @", () => {
    expect(mentionAt("ping @sara@exa", 14)).toEqual({ query: "sara@exa", at: 5 });
    expect(mentionAt("ping @sara@example.com", 22)).toEqual({ query: "sara@example.com", at: 5 });
  });

  it("a finished word is not a name being written", () => {
    expect(mentionAt("ping @sara and", 14)).toBeNull();
  });

  // What is being written is what is in front of the caret, not what is in the box: moving back
  // into an old name is editing it, and moving past one is not.
  it("reads from the caret, not the end", () => {
    expect(mentionAt("@sara later", 4)).toEqual({ query: "sar", at: 0 });
    expect(mentionAt("@sara later", 11)).toBeNull();
  });

  it("has nothing to say about nothing", () => {
    expect(mentionAt("", 0)).toBeNull();
    expect(mentionAt(null, 0)).toBeNull();
  });
});

describe("withMention", () => {
  it("replaces the partial name and leaves the caret after it", () => {
    expect(withMention("ping @sa", 5, 8, "sara")).toEqual({
      value: "ping @sara ",
      caret: 11,
    });
  });

  it("keeps what comes after the caret", () => {
    expect(withMention("ping @sa please", 5, 8, "sara")).toEqual({
      value: "ping @sara  please",
      caret: 11,
    });
  });

  it("writes over an empty name", () => {
    expect(withMention("@", 0, 1, "sara")).toEqual({ value: "@sara ", caret: 6 });
  });
});

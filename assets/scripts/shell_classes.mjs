// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// Writes every class Tailwind's own scanner finds in the given sources, one per line, to the file
// named first: `bun shell_classes.mjs <out> <source>...`, each source an absolute path or glob as an
// `@source` line takes it. `mix compile_static_css` runs it at build time: a release ships none of
// these sources, and the runtime compiler reads this list in their place.
import { writeFileSync } from "node:fs";
import { Scanner } from "@tailwindcss/oxide";

const [out, ...patterns] = process.argv.slice(2);
const sources = patterns.map((pattern) => ({ base: process.cwd(), pattern, negated: false }));

writeFileSync(out, new Scanner({ sources }).scan().join("\n") + "\n");

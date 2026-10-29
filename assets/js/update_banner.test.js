// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { beforeEach, describe, expect, test, vi } from "vitest";

import { showUpdateBanner } from "./update_banner.js";

const banners = () => document.querySelectorAll("#mishka-update-banner");

beforeEach(() => {
  document.body.innerHTML = "";
});

describe("showUpdateBanner", () => {
  test("says the page was updated and offers a refresh", () => {
    showUpdateBanner(document, () => {});

    const [banner] = banners();
    expect(banner.textContent).toContain("This page was updated.");
    expect(banner.querySelector("button").textContent).toBe("Refresh");
  });

  test("the refresh button reloads the page", () => {
    const reload = vi.fn();
    showUpdateBanner(document, reload);

    document.querySelector("#mishka-update-banner button").click();

    expect(reload).toHaveBeenCalledOnce();
  });

  // A rebuilt JS bundle and a rebuilt page, or two saves in a row, are one thing to tell a reader.
  test("a second announcement adds no second banner", () => {
    showUpdateBanner(document, () => {});
    showUpdateBanner(document, () => {});

    expect(banners()).toHaveLength(1);
  });
});

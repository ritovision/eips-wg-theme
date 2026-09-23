(() => {
    const storageKey = "eips.color-mode";
    const root = document.documentElement;
    const systemMode = window.matchMedia("(prefers-color-scheme: dark)");
    let preference = null;

    const readPreference = () => {
        try {
            const value = window.localStorage.getItem(storageKey);
            return value === "light" || value === "dark" ? value : null;
        } catch {
            return null;
        }
    };

    const applyMode = () => {
        const mode = preference || (systemMode.matches ? "dark" : "light");
        root.setAttribute("data-bs-theme", mode);

        document.querySelectorAll("[data-color-mode-style]").forEach((link) => {
            link.media = link.getAttribute("data-color-mode-style") === mode ? "all" : "not all";
        });

        const button = document.querySelector("[data-color-mode-toggle]");
        if (button) {
            button.setAttribute("aria-checked", String(mode === "dark"));
            button.title = mode === "dark" ? "Switch to light mode" : "Switch to dark mode";
        }
    };

    preference = readPreference();
    // This script runs in the head so a saved choice is applied before the body paints.
    applyMode();

    const init = () => {
        const control = document.querySelector("[data-color-mode-control]");
        const button = document.querySelector("[data-color-mode-toggle]");
        if (!control || !button) {
            return;
        }

        button.addEventListener("click", () => {
            preference = root.getAttribute("data-bs-theme") === "dark" ? "light" : "dark";
            try {
                window.localStorage.setItem(storageKey, preference);
            } catch {
                // The switch still works when browser privacy settings block storage.
            }
            applyMode();
        });

        applyMode();
        control.hidden = false;
    };

    systemMode.addEventListener("change", () => {
        if (preference === null) {
            applyMode();
        }
    });

    window.addEventListener("storage", (event) => {
        if (event.key === storageKey || event.key === null) {
            preference = readPreference();
            applyMode();
        }
    });

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init, { once: true });
    } else {
        init();
    }
})();

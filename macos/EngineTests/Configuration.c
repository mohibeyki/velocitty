// SPDX-License-Identifier: GPL-3.0
// Exercises the real Swift/Zig ABI against the built static engine.
#include "velokit.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

_Static_assert(sizeof(ghostty_input_trigger_s) == 12, "trigger ABI size");
_Static_assert(offsetof(ghostty_input_trigger_s, key) == 4, "trigger key offset");
_Static_assert(offsetof(ghostty_input_trigger_s, mods) == 8, "trigger modifiers offset");
_Static_assert(sizeof(((ghostty_input_trigger_s *)0)->mods) == 4, "C modifier width");

static void accepts(const char *key, const char *value) {
    ghostty_config_t config = velokit_config_new();
    assert(config);
    if (!velokit_config_set(config, key, value) || !velokit_config_finalize(config, "/tmp")) {
        fprintf(stderr, "%s: %s\n", key, velokit_config_error(config));
        assert(0);
    }
    velokit_config_free(config);
}

static void rejects(const char *key, const char *value) {
    ghostty_config_t config = velokit_config_new();
    assert(config);
    assert(!velokit_config_set(config, key, value));
    const char *error = velokit_config_error(config);
    assert(error && strstr(error, key));
    velokit_config_free(config);
}

int main(int argc, char **argv) {
    assert(velokit_init((uintptr_t)argc, argv) == GHOSTTY_SUCCESS);
    ghostty_config_t defaults = velokit_config_new();
    assert(defaults);
    const char *formatted = velokit_config_format(defaults, "font-size");
    assert(formatted && strcmp(formatted, "font-size = 13\n") == 0);
    assert(strcmp(velokit_config_format(defaults, "quit-after-last-window-closed"),
                  "quit-after-last-window-closed = false\n") == 0);
    assert(!velokit_config_format(defaults, "not-a-setting"));
    velokit_config_free(defaults);
    const char *valid[][2] = {
        {"font-family", "Menlo"}, {"font-size", "14.5"},
        {"font-feature", "-calt"}, {"font-style-italic", "false"},
        {"font-variation", "wght=500"}, {"font-codepoint-map", "U+E000-U+F8FF=Menlo"},
        {"background", "#102030"}, {"foreground", "#abcdef"},
        {"palette", "1=#ff0000"}, {"cursor-style", "bar"}, {"cursor-style-blink", "false"},
        {"minimum-contrast", "3"}, {"adjust-cell-height", "10%"},
        {"window-padding-x", "8,12"}, {"window-padding-balance", "true"},
        {"scrollback-limit-lines", "10000"}, {"scrollback-limit-bytes", "1000000"},
        {"scrollback-compression", "false"}, {"scroll-to-bottom", "keystroke,no-output"},
        {"clipboard-trim-trailing-spaces", "true"}, {"clipboard-write", "deny"},
        {"keybind", "ctrl+shift+j=text:hello"}, {"key-remap", "ctrl=super"},
        {"command-palette-entry", "title:Copy ANSI,action:\"write_screen_file:copy,vt\""},
        {"command", "/bin/zsh"}, {"env", "TEST=a=b"}, {"input", "raw:hello\\n"},
        {"wait-after-command", "true"}, {"title", "Configured terminal"},
        {"term", "xterm-256color"}, {"image-storage-limit", "1000000"},
        {"font-size", ""}, {"font-family", ""},
        // Newlines and '=' belong to the value, never a second setting.
        {"env", "TEST=line one\n--font-size=not-a-number"},
    };
    for (size_t i = 0; i < sizeof(valid) / sizeof(valid[0]); i++) accepts(valid[i][0], valid[i][1]);
    rejects("font-size", "not-a-number");
    rejects("font-size", "nan");
    rejects("font-size", "inf");
    rejects("background", "not-a-color");
    rejects("cursor-style", "not-a-style");
    rejects("scrollback-limit-lines", "-1");
    rejects("keybind", "invalid-key-name=not_an_action");
    rejects("not-a-setting", "true");

    // Repeated values and a failed parse must remain attached to their own
    // candidate configuration. The next configuration must be clean.
    ghostty_config_t config = velokit_config_new();
    assert(velokit_config_set(config, "font-family", "Menlo"));
    assert(velokit_config_set(config, "font-family", "Monaco"));
    assert(velokit_config_set(config, "palette", "0=#112233"));
    assert(velokit_config_set(config, "palette", "1=#445566"));
    assert(velokit_config_finalize(config, "/tmp"));
    velokit_config_free(config);
    config = velokit_config_new();
    assert(!velokit_config_set(config, "cursor-style", "invalid"));
    assert(velokit_config_error(config));
    velokit_config_free(config);
    accepts("font-size", "13");
    config = velokit_config_new();
    assert(velokit_config_finalize(config, "/tmp"));
    const char *mode = NULL;
    bool initial = false;
    double opacity = 0;
    uint32_t width = 1;
    assert(velokit_config_get(config, &mode, "fullscreen", strlen("fullscreen")));
    assert(strcmp(mode, "false") == 0);
    assert(velokit_config_get(config, &initial, "initial-window", strlen("initial-window")) && initial);
    assert(velokit_config_get(config, &opacity, "background-opacity", strlen("background-opacity")) && opacity == 1);
    assert(velokit_config_get(config, &width, "window-width", strlen("window-width")) && width == 0);
    velokit_config_free(config);
    config = velokit_config_new();
    assert(velokit_config_finalize(config, "/tmp"));
    ghostty_input_trigger_s trigger;
    memset(&trigger, 0xA5, sizeof(trigger));
    assert(velokit_config_trigger(config, "copy_to_clipboard", &trigger));
    assert(trigger.tag == GHOSTTY_TRIGGER_UNICODE && trigger.key.unicode == 'c');
    assert(trigger.mods == GHOSTTY_MODS_SUPER);
    assert(velokit_config_trigger(config, "start_search", &trigger));
    assert(trigger.tag == GHOSTTY_TRIGGER_UNICODE && trigger.key.unicode == 'f');
    assert(velokit_config_set(config, "keybind", "super+f=unbind"));
    assert(!velokit_config_trigger(config, "start_search", &trigger));
    assert(velokit_config_set(config, "keybind", "global:super+shift+k=toggle_visibility"));
    memset(&trigger, 0xA5, sizeof(trigger));
    assert(velokit_config_global_trigger(config, 0, &trigger));
    assert(trigger.tag == GHOSTTY_TRIGGER_UNICODE && trigger.key.unicode == 'k');
    assert(trigger.mods == (GHOSTTY_MODS_SUPER | GHOSTTY_MODS_SHIFT));
    assert(!velokit_config_global_trigger(config, 1, &trigger));
    velokit_config_free(config);
    puts("Engine configuration tests passed.");
    return 0;
}

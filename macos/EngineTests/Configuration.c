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

enum ValueKind { BOOL, INT16, UINT32, DOUBLE, MILLISECONDS, STRING, COLOR, PATH, COMMANDS, NONE };

static void checked_getters(void) {
    ghostty_config_t config = velokit_config_new();
    assert(config);
    assert(velokit_config_set(config, "window-position-x", "-24"));
    assert(velokit_config_set(config, "background-opacity", "0.625"));
    assert(velokit_config_set(config, "background-blur", "macos-glass-regular"));
    assert(velokit_config_set(config, "bell-features", "audio"));
    assert(velokit_config_set(config, "window-title-font-family", "Menlo"));
    assert(velokit_config_set(config, "background", "#123456"));
    assert(velokit_config_set(config, "bell-audio-path", "/tmp"));
    assert(velokit_config_finalize(config, "/tmp"));
    const struct { const char *key; enum ValueKind kind; } cases[] = {
        {"initial-window", BOOL}, {"window-position-x", INT16},
        {"background-blur", INT16}, {"bell-features", UINT32},
        {"window-width", UINT32}, {"background-opacity", DOUBLE},
        {"resize-overlay-duration", MILLISECONDS}, {"window-title-font-family", STRING},
        {"fullscreen", STRING}, {"background", COLOR},
        {"bell-audio-path", PATH}, {"command-palette-entry", COMMANDS},
        {"not-a-setting", NONE}, {"title", NONE},
        // f32 must not be written into a double, even though both are floating point.
        {"font-size", NONE},
    };
    union Output {
        bool boolean; int16_t short_integer; uint32_t bits; double number;
        uintptr_t milliseconds; const char *string; ghostty_config_color_s color;
        ghostty_config_path_s path; ghostty_config_command_list_s commands;
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        for (enum ValueKind kind = BOOL; kind < NONE; ++kind) {
            struct { uint64_t before; union Output value; uint64_t after; } output, original;
            memset(&output, 0xA5, sizeof(output));
            memcpy(&original, &output, sizeof(output));
            bool found = false;
            switch (kind) {
                case BOOL: found = velokit_config_get_bool(config, cases[i].key, &output.value.boolean); break;
                case INT16: found = velokit_config_get_int16(config, cases[i].key, &output.value.short_integer); break;
                case UINT32: found = velokit_config_get_uint32(config, cases[i].key, &output.value.bits); break;
                case DOUBLE: found = velokit_config_get_double(config, cases[i].key, &output.value.number); break;
                case MILLISECONDS: found = velokit_config_get_milliseconds(config, cases[i].key, &output.value.milliseconds); break;
                case STRING: found = velokit_config_get_string(config, cases[i].key, &output.value.string); break;
                case COLOR: found = velokit_config_get_color(config, cases[i].key, &output.value.color); break;
                case PATH: found = velokit_config_get_path(config, cases[i].key, &output.value.path); break;
                case COMMANDS: found = velokit_config_get_commands(config, cases[i].key, &output.value.commands); break;
                case NONE: assert(0);
            }
            if (found != (kind == cases[i].kind)) fprintf(stderr, "getter %d: %s\n", kind, cases[i].key);
            assert(found == (kind == cases[i].kind));
            assert(output.before == original.before && output.after == original.after);
            if (!found) assert(memcmp(&output, &original, sizeof(output)) == 0);
        }
    }
    bool initial = false;
    int16_t position = 0, blur = 0;
    uint32_t bits = 0;
    double opacity = 0;
    uintptr_t milliseconds = 0;
    const char *family = NULL, *mode = NULL;
    ghostty_config_color_s color = {0};
    ghostty_config_path_s path = {0};
    ghostty_config_command_list_s commands = {0};
    assert(velokit_config_get_bool(config, "initial-window", &initial) && initial);
    assert(velokit_config_get_int16(config, "window-position-x", &position) && position == -24);
    assert(velokit_config_get_int16(config, "background-blur", &blur) && blur == -1);
    assert(velokit_config_get_uint32(config, "bell-features", &bits) && bits == 14); // audio plus default attention/title
    assert(velokit_config_get_double(config, "background-opacity", &opacity) && opacity == 0.625);
    assert(velokit_config_get_milliseconds(config, "resize-overlay-duration", &milliseconds) && milliseconds == 750);
    assert(velokit_config_get_string(config, "window-title-font-family", &family) && strcmp(family, "Menlo") == 0);
    assert(velokit_config_get_string(config, "fullscreen", &mode) && strcmp(mode, "false") == 0);
    assert(velokit_config_get_color(config, "background", &color) && color.r == 0x12 && color.g == 0x34 && color.b == 0x56);
    assert(velokit_config_get_path(config, "bell-audio-path", &path) && strcmp(path.path, "/tmp") == 0 && !path.optional);
    assert(velokit_config_get_commands(config, "command-palette-entry", &commands) && commands.len > 0);
    velokit_config_free(config);
}

int main(int argc, char **argv) {
    assert(velokit_init((uintptr_t)argc, argv) == GHOSTTY_SUCCESS);
    checked_getters();
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

    // Applied notifications carry borrowed configs. Copies must survive their
    // source, and preparing a local override must leave the base unchanged.
    config = velokit_config_new();
    assert(velokit_config_set(config, "background-opacity", "0.4"));
    assert(velokit_config_finalize(config, "/tmp"));
    ghostty_config_t copy = velokit_config_clone(config);
    assert(copy && velokit_config_set(copy, "background-opacity", "1"));
    double base_opacity = 0;
    assert(velokit_config_get_double(config, "background-opacity", &base_opacity));
    assert(base_opacity == 0.4);
    velokit_config_free(config);
    assert(velokit_config_get_double(copy, "background-opacity", &base_opacity));
    assert(base_opacity == 1);
    assert(!velokit_config_diagnostic(copy, 0));
    velokit_config_free(copy);

    // Recoverable path-expansion errors must not prevent finalization. Preserve
    // every diagnostic, and allow a prepared override on the resulting config.
    char long_path[301];
    memset(long_path, 'x', sizeof(long_path) - 1);
    long_path[sizeof(long_path) - 1] = '\0';
    config = velokit_config_new();
    assert(velokit_config_set(config, "bell-audio-path", long_path));
    assert(velokit_config_set(config, "background-image", long_path));
    assert(velokit_config_finalize(config, "/tmp"));
    assert(velokit_config_diagnostic(config, 0));
    assert(velokit_config_diagnostic(config, 1));
    assert(!velokit_config_diagnostic(config, 2));
    ghostty_config_path_s cleared_path;
    assert(velokit_config_get_path(config, "bell-audio-path", &cleared_path));
    assert(cleared_path.path[0] == '\0');
    copy = velokit_config_clone(config);
    assert(copy && velokit_config_set(copy, "background-opacity", "1"));
    velokit_config_free(config);
    assert(velokit_config_diagnostic(copy, 1));
    velokit_config_free(copy);

    config = velokit_config_new();
    assert(velokit_config_finalize(config, "/tmp"));
    const char *mode = NULL;
    bool initial = false;
    double opacity = 0;
    uint32_t width = 1;
    assert(velokit_config_get_string(config, "fullscreen", &mode));
    assert(strcmp(mode, "false") == 0);
    assert(velokit_config_get_bool(config, "initial-window", &initial) && initial);
    assert(velokit_config_get_double(config, "background-opacity", &opacity) && opacity == 1);
    assert(velokit_config_get_uint32(config, "window-width", &width) && width == 0);
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

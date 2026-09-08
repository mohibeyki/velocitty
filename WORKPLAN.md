# Implementation work plan

Scope: macOS features only. Keep focus and presentation in Velocitty, terminal lifetime in herdr. Settings GUI edits TOML. Remote validation uses an isolated server reached through this laptop's IP address. No quick terminal, AppleScript, auto-updates, signing, notarization, publishing, or pushes. Distribution infrastructure is deferred.

Each step ends with focused validation and a local commit. Consult a subagent for uncertain design choices. Preserve actual user sessions.

- [x] 1. Connection recovery: retain pane identity/layout, distinguish shell exit from attachment failure, retry with backoff, expose retry state. Validate isolated attachment interruption, real exit, cancellation, no duplicate attachments.
- [x] 2. Pane controls: draggable dividers, zoom, equalization, all split directions, styling. Validate nested splits, minimum sizes, selection and restoration.
- [ ] 3. Rearrangement: move tabs across namespaces and panes across tabs, enable mixed-namespace presentation where ownership remains clear. Validate IDs/process lifetime and persistence.
- [x] 4. Workspace search: centered search, keyboard navigation across namespaces/tabs/agents, waiting-agent discovery. Validate dynamic result updates and focus.
- [ ] 5. Deferred settings: implement applicable Ghostty pane/window behavior, retain deliberate exclusions. Validate defaults, reload, export and invalid values.
- [ ] 6. Settings GUI: native editor backed by existing TOML, preserve unknown settings/comments, validation and reload. Validate round-trip and external edits.
- [ ] 7. Remote support: use herdr 0.9 multi-server facilities, explicit server identity, config/UI, reconnect and persistence. Validate via laptop IP with isolated sessions; no changes to existing work sessions.
- [ ] 8. Agent polish and integration: consistent status presentation, stale-state handling, navigation. Run focused end-to-end checks, update README roadmap, remove this temporary work plan, commit final docs.

Progress:
- Baseline clean. Installed herdr is 0.8.2; investigating 0.9 without replacing the user's executable.

- Step 1 validated: build and isolated workspace GUI test passed, including repeated recovery requests and input reaching the original terminal ID. Recovery retries eight times with capped backoff; manual retry remains available.

- Step 2 validated: build and isolated GUI checks passed for split ratios, equalization, left placement, zoom and restoration. Left/up use process-preserving split+swap; backend incidental selection is ignored. Divider commits one ratio on release.

- Step 3 moves validated and complete: split-tab moves across namespaces and pane detachment preserve terminal IDs/processes; focused GUI test passed. Mixed-namespace simultaneous presentation remains to be addressed with endpoint presentation in step 7.

- Step 4 validated: native centered search and Cmd-P, live results across windows, and selection into the existing pane passed the focused GUI test.

- Step 5 pane/window settings validated: 27 configuration tests and focused GUI checks passed, including live font-size inheritance. Close undo/redo and Dock drop policy remain separate work within this step.

# iOS Agent Chat Redesign

**Date:** 2026-08-03  
**Status:** Approved direction  
**Scope:** iOS UI only

## Goal

Replace the current generic SwiftUI presentation with a focused, light-only interface inspired by ChatGPT and Claude. The app should feel like a mobile surface for reading an agent result and sending a reply, rather than a conventional task manager or admin panel.

The backend contract and task workflow remain unchanged. A task still contains one agent result and supports one reply; the redesign must not imply that the server supports an unlimited multi-turn conversation.

## Non-goals

- No backend or API changes.
- No changes to APNs, device registration, authentication, or persistence.
- No dark theme.
- No true multi-message chat history.
- No new filtering, search, analytics, or task-management features.

## Visual direction

The interface is designed specifically for a light appearance:

- white primary background;
- near-black primary text;
- soft neutral gray secondary surfaces;
- one restrained accent color;
- semantic color used only when a status requires attention;
- minimal borders and shadows;
- generous but controlled spacing;
- system typography with a clear content hierarchy;
- monospaced typography reserved for logs and technical identifiers.

The design should resemble a continuous AI conversation rather than a collection of cards. Avoid decorative chat bubbles, excessive capsules, gradients, glass effects, and dashboard-style widgets.

## Navigation

Keep the existing list-to-detail navigation because the server exposes multiple tasks. Remove the persistent Settings tab so the main experience is not framed as a generic two-tab utility.

The root screen contains:

- the product title `tax`;
- the task/conversation list;
- a settings button in the top-right toolbar.

Settings opens as a sheet or pushed destination. Push routing continues to open the corresponding task detail using the existing `AppState` navigation path.

## Conversation list

Each task is presented as a conversation preview, not as a task-management row.

A row contains:

- task title as the primary line;
- a short preview of the latest meaningful content;
- relative or compact update time;
- a subtle unread/action-required indicator when a reply is pending.

Remove the visible status capsule. Completed and failed states may use a small icon or restrained semantic label only when necessary. Keep pull-to-refresh; remove the redundant refresh toolbar button. Empty, loading, and error states remain accessible and actionable but should use the same minimal visual language.

## Task detail

Present the detail as a continuous vertical transcript:

1. The original request/context is shown as the initiating content.
2. The agent result is the primary readable response.
3. Technical logs are hidden behind a disclosure control such as **Show execution details**.
4. An existing user reply is shown as the final user contribution.

Do not show task ID, raw dates, and backend status as prominent content. Put technical metadata in a `More` menu or a secondary information sheet where it remains copyable.

Long text remains selectable. Logs use a monospaced font and preserve line breaks. The content should support Dynamic Type without fixed-height containers.

## Reply composer

Replace the separate reply sheet with a composer attached to the bottom of the task detail using `safeAreaInset`.

The composer contains:

- an expanding text input;
- a short placeholder;
- a circular send button;
- disabled and sending states;
- keyboard-safe spacing.

Sending continues to call the existing `POST /task/{id}/reply` endpoint through `ReplyStore`. On success, update the local task and refresh the list. If the task already has a reply or its status forbids another response, show the existing reply and disable or hide the composer according to current server behavior.

A send failure must retain the draft and present a recoverable error without dismissing the screen.

## Settings

Settings remains functionally unchanged and continues to manage:

- server URL;
- API key;
- push mode;
- device token;
- health check and registration actions.

It may continue using `Form`, because it is a secondary administrative screen. Simplify labels and status messaging where possible, but do not change Keychain, UserDefaults, or notification behavior as part of this redesign.

## Architecture and data flow

Preserve the current Observation-based architecture:

- `TaskListStore` owns list loading state;
- `TaskDetailStore` owns the selected task;
- `ReplyStore` owns draft and submission state;
- `SettingsStore` provides the configured service;
- `AppState` owns navigation and refresh events.

The redesign should primarily modify views and add small reusable visual components. It must not move network operations into SwiftUI view bodies or introduce a parallel model layer.

Suggested view structure:

- `ConversationListView` / revised `TaskListView`;
- `ConversationRow`;
- revised `TaskDetailView`;
- `AgentResponseView`;
- `ExecutionDetailsView`;
- `ReplyComposer`;
- `TaskMetadataView`.

Names may remain task-oriented internally to minimize churn.

## Accessibility

- Support Dynamic Type and multiline content.
- Keep a minimum 44-point hit target for toolbar and send buttons.
- Give status indicators meaningful VoiceOver labels; never encode state by color alone.
- Preserve accessibility identifiers used by UI tests unless tests are intentionally updated in the same change.
- Respect Reduce Motion for any optional transitions.
- Maintain sufficient contrast on gray surfaces and placeholder text.

## Validation

Implementation is complete when:

1. The app builds with Swift 6 strict concurrency enabled.
2. Existing unit tests continue to pass.
3. UI tests are updated for the new settings navigation and inline composer.
4. List loading, empty, content, stale-content error, and retry states are verified.
5. Task detail is verified with missing context, missing logs, long logs, and an existing reply.
6. Reply success and failure are verified; failed sends retain the draft.
7. Push navigation still opens the correct task.
8. The main flow is visually checked in light appearance at standard and accessibility text sizes.
9. No backend endpoint or payload schema changes are introduced.

# Shared Home frontend

Both engine adapters load these same HTML, CSS, script and font bytes. The frontend
owns presentation and emits requests; it never opens files, signs in, installs
packages, deletes saves or navigates to external sites itself.

Layout originates in `SBF6MapSelector`, its helpers in `BF6BuildMode.cpp`, and
`SBF6ExperienceGrid` in `BF6PortalProfile.cpp`. Theme values match `BF6Theme.h`.
The map frame is 302 CSS pixels wide with 300 by 169 art, 12-pixel grid spacing,
22-pixel size badges, and inline name-bar resume/backup controls. Slate font point
sizes are expressed as CSS points. The exact Roboto regular/bold font files ship
with their Apache 2 license in `fonts/`. Browser and Slate rasterization are not
assumed pixel-identical merely because geometry/font inputs agree.

Call `window.bf6Home.setState(object)` with a complete snapshot:

```json
{
  "maps": [{"id":"mp_example","name":"Example","image":"../mapthumbs/MP_Example.jpg","size":"L","paid":true,"objectCount":1234,"available":true,"saves":[{"id":"save1","name":"My map","canLink":false,"canDelete":false}],"backupCount":0}],
  "groups": [{"id":"paid","label":"Battlefield 6 maps"},{"id":"free","label":"RedSec maps - free for everyone"}],
  "actions": [{"id":"sdk_setup","label":"SDK Setup","visible":true,"enabled":true,"placement":"header","tooltip":"","unread":false}],
  "busy":false,
  "status":"",
  "experiences":[]
}
```

Optional top-level `eyebrow`, `title`, `subtitle`, and `experienceHeading` replace
the original labels. Missing object counts stay undisplayed. Linked Portal experiences
accept `id`, `name`, `image`, `available`, `subtitle`, `imported`, `nameOverlay`,
and `searchText`. Experience search filters name, ID and searchText locally and
retains the query/caret during host refreshes. The bottom card section is reserved
for those linked experiences. Local saves appear only in their map's Resume menu;
the frontend ignores a legacy `projects` field and refuses `open_project` requests.

Action placement is `header`, `prepare`, `footer` or `experiences`. Busy disables
ordinary requests; preparation controls remain available to open/pause progress.
Use `allowWhileBusy:true` for an explicitly supported cancellation/status action.
Hidden/disabled actions cannot dispatch. The host must independently revalidate
all requests against its current state and perform any necessary confirmations.

Images accept only `images/<name>`, `mapthumbs/<name>` or `../mapthumbs/<name>`
with PNG/JPEG/WebP extensions and canonical filenames. Trusted hosts may instead
provide bounded PNG/JPEG/WebP base64 data URIs (approximately 4 MiB decoded maximum).
Remote URLs, arbitrary file paths, SVG data, traversal and percent-encoded paths
are rejected. Hosts must source image bytes from approved local assets. Metadata
is assigned through textContent, never HTML interpretation.

Transport preference is a trusted initialization hook
`window.bf6HomeHostPost(jsonText)`, then `window.ipc.postMessage(jsonText)`, then
`console.log('BF6_HOME:' + jsonText)`. The hook lets the Godot adapter wrap requests
in the native offline host's envelope without changing its frozen IPC object.

Every event has `channel:"bf6-home"` and one of:

| action | Additional fields |
| --- | --- |
| ready | none |
| tool | id of a visible enabled configured action |
| open_map, backups | id of a current map |
| resume, link_save, delete_save | id of a current map and saveId belonging to it |
| open_experience | id of a current linked Portal experience |

No source paths or caller-added fields are forwarded. Unsupported operations,
stale IDs and unavailable capabilities are refused. Link/delete controls appear
only when the corresponding save capability is explicitly true.

Tests: `node Tools/tests/home_frontend.test.cjs`, and
`Tools/tests/home_frontend_browser.py --browser <chromium> --output <new-folder>`.
The browser suite checks actual rendering geometry, images, fonts, literal hostile
metadata, real resume clicks, focus/menu/search retention and frozen-IPC bridging.

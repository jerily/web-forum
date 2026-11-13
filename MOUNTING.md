# Mounting web-forum onto a site

The host owns the router, connection and account mount. The forum owns its
routes, templates and discussion tables. Mount configuration is captured by the
handlers, so separate workers and sites do not share an active global forum.

## Initialize and mount

Use the same account store and account mount for the forum. Initialize tables
once through an explicit maintenance step before serving requests:

```tcl
package require web-forum 0.1.10
set router [::tpathexp::router]
set accountStore [::web::user::create -connection $connection -config [dict create tenant mysite \
    aead $aeadHandle mac $macHandle email_hash_salt $emailHashSalt]]
::web::user::initdb $connection
::web::forum::initdb $connection
set accounts [::web::user::mount $router -store $accountStore -config [dict create prefix /user origin https://community.example master_template $master]]
set forum [::web::forum::mount $router -store $accountStore -user $accounts \
    -config [dict create prefix /forum title Discussions master_template $master]]
```

`$connection` is an autocommit tpersist connection (`-autobegin 0`). The account
store selects the tenant; forum queries use that same tenant. Each worker owns
its connection and registered Tink handles for the lifetime of its router.
`initdb` does not run inside `mount` or request handlers. Destroy the router,
unregister the worker's handles and close its connection during shutdown.

## Mount options

| Option | Meaning |
| --- | --- |
| `-store` | Required account store from `web-user::create`. |
| `-user` | Required account mount from `web-user::mount`, using the same store. |
| `-prefix` | Non-root local path, default `/forum`. |
| `-config` | Dictionary with `prefix`, `title`, `master_template`, `templates`, typed `properties`, named `widgets` callbacks, and limits below. |

`master_template` is trusted template source replacing `page.html.jinja` for this
mount. `templates` maps template names to trusted source overrides. Overrides
are local to the mount and validated before routes are added. The master uses
`{% block body %}`. Templates receive `title`, `brand`, `prefix`, `view`,
`topic_title`, `topic_html`, `topic_profile_widget`, `action_url`, `login_url`, `csrf`, typed `signed_in`,
and typed `items`. Titles are escaped. `topic_html` and `items[].body_html`
contain cmark-gfm output with raw HTML and unsafe URLs disabled; only those
rendered fields are marked safe. Stored Markdown is never marked safe.
Creation times appear beside authors in UTC using semantic `<time>` elements.
Custom templates receive `topic_created_at_datetime` and `topic_created_at_label`,
and each item has `created_at_datetime` and `created_at_label`. The datetime is
ISO 8601 UTC; the label is `YYYY-MM-DD HH:MM UTC`. Existing records use their
stored creation time without a schema migration.
The forum currently has no dynamic host-context callback.

Mount the forum before catch-all routes and use a prefix that does not overlap
another package. The host maps `httpMethod` to `method`, preserves request
headers/body/path, and passes trusted connection context to:

```tcl
set response [$router dispatch $request $context]
```

The response contains `statusCode`, `headers` and `body`. Unexpected errors
propagate to the host, which should return a generic 500 without logging request
credentials. Expected account/validation failures return an HTTP status.

## Endpoints and access

| Path | Methods | Behavior |
| --- | --- | --- |
| `/forum`, `/forum/` | GET/HEAD | Public list of the newest 100 threads. |
| `/forum/new` | GET/HEAD, POST | New-thread form; POST requires `title body csrf`. |
| `/forum/topic/:id` | GET/HEAD, POST | Public topic and latest 100 replies; POST requires `body csrf`. |
| `/forum/_assets/:asset` | GET/HEAD | Bundled editor CSS/JavaScript; unknown names return 404. |

Paths are relative to the chosen prefix. Successful posts redirect with 303 to
the topic. An anonymous GET of the new-thread form redirects to the account
login route; anonymous POST is rejected. Logged-in members may create threads
and reply. Every POST checks the account mount's CSRF token and origin policy.
Pending verification, recovery and MFA sessions do not count as signed in.

Defaults are 160 characters per title, 10,000 per body, 100 items per list and
30 posting attempts per account throttle window (default 15 minutes). Configure
`title_max_length`, `body_max_length`, `page_size` and `post_limit` in `-config`. IDs use KSUIDs. Public
author labels use the host-provided profile widget, with `Member` as the fallback.

There are no edit/delete, upload, moderation, pagination or role APIs yet.
Account setup, email delivery, session rotation and cookie configuration belong
to `web-user`; see its [mounting guide](https://github.com/jerily/web-user/blob/main/MOUNTING.md).

## Visual Markdown editor

A `data-markdown-editor` textarea uses the same Lexical visual/source editor
shipped by web-wiki and web-blog. Every forum mount serves its own files; no wiki
or blog mount is required. A custom master uses `editing` (boolean) and `assets`:

```jinja
{% if editing %}
<link rel="stylesheet" href="{{ assets }}/editor.css">
<script defer src="{{ assets }}/markdown-editor.bundle.js"></script>
{% endif %}
```

Keep the master block `{% block body %}` and textarea name `body`. The editor
submits Markdown through the ordinary form with its CSRF field. Server checks
apply even if browser validation is bypassed. Existing plain-text bodies need no
schema migration. Source and licenses are installed in `frontend`; rebuild using
the included npm lockfile. Routes are registered one by one in `mount` with
separate index, new-topic, topic/reply and asset handlers.

The editor stylesheet supplies fallback colors for its border, background, text
and focus outline. Hosts may override the HSL theme variables used in
`assets/editor.css`; defining them is optional. Visual and source modes share
the same visible content-area styling.

## Request validation

`assets/operations.json` contains inline OpenAPI operations for each POST form.
Mounting applies configured limits and captures the resulting JSON. `topenapi`
0.2.0 validates required fields, types, lengths and allowed operations after
strict form decoding and CSRF verification. Unknown form fields are rejected.
Authorization, password checks, MFA replay and transactions remain in the handlers.
No credential-bearing validation diagnostics are returned to the browser.

## Shared widgets

`widgets` maps slot names to trusted command prefixes. The forum's `profile` slot
calls its provider with `properties request context`, where `properties` contains
`user_id`. Returned HTML is inserted into topic lists, topic author labels and
replies. A repeated author is rendered once per page; there is no global cache.
The provider owns escaping and privacy decisions. No callback means `Member`.

```tcl
set widgets [dict create profile [list ::web::user::widget $accounts profile]]
::web::forum::mount $router -store $store -user $accounts \
    -config [dict create widgets $widgets]
```

The [WIDGETS.md contract](https://github.com/jerily/web-user/blob/main/WIDGETS.md)
covers provider replacement, first-name display, template overrides and upgrades.
Custom forum templates can render `topic_profile_widget` and each item's
`profile_widget` with `safe`; all other ordinary text fields remain escaped.

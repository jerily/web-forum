# web-forum

Licensed under the [MIT License](LICENSE).

A community discussion package with paginated topics and replies, public author
profiles, optional approval before publication, and optional posting CAPTCHA.
Moderators can approve/reject submissions, hide/restore topics and replies, and
lock/unlock discussions. Every moderation action records who acted, when, and
why. Permission checks and CSRF protection apply on the server.

Bodies are Markdown, rendered with raw HTML and unsafe links disabled. The forum
includes a visual/source editor and responsive styling that also works inside a
host's shared layout.

```tcl
package require web-forum
::web::forum::initdb $connection
set forum [::web::forum::mount $router -store $accountStore -user $accountMount \
    -config [dict create prefix /forum master_template $siteMaster]]
```

`accountStore` and `accountMount` are returned by `web-user::create` and
`web-user::mount`. The forum deliberately depends on web-user's identity, CSRF,
rate-limit and typed persistence helpers. Tenant/connection/key lifecycle belongs
to the host. `initdb` is explicit and must precede serving requests.

Routes: GET `/forum` and `/forum/`; GET/POST `/forum/new`; GET/POST
`/forum/topic/:id`. POST new requires `title body csrf`; POST reply requires
`body csrf`. IDs use `ksuid-tcl` with a resource prefix: `topic_<ksuid>`,
`reply_<ksuid>`, and `moderation_<ksuid>`. Topic routes and moderation actions
validate the prefix for the requested resource. Posts are limited to 10000
characters and titles to 160; members are limited to 30 posting attempts per
15 minutes. Public author
labels use the host-provided profile widget, with `Member` as the fallback. Anonymous
GET of the new-thread form redirects to login; anonymous POST is rejected.
Topics, replies and discussion lists show creation dates and times in UTC.

Configuration accepts `prefix`, `title`, `master_template`, named `templates`,
typed template `properties`, named `widgets` callbacks, `page_size` (20), `body_max_length` (10000),
`title_max_length` (160), `post_limit` (30), `moderation` (false), and
`posting_captcha` (false). Limits above are defaults.
The master defines `{% block body %}`. See [MOUNTING.md](MOUNTING.md) for the complete mounting contract and
`example-community` for a host that also mounts web-wiki and web-blog.

Install with `ttrek install -y web-forum`; it includes `web-user` and its native
dependencies. A source checkout can also be installed with CMake or added to
`TCLLIBPATH`.

Each route is listed explicitly in `mount` with its own handler. The package
serves `/_assets/editor.css` and `/_assets/markdown-editor.bundle.js` beneath its
prefix. Custom masters load these when typed `editing` is true, using `assets`.
The default master and example-community layout do this. Without JavaScript,
the Markdown textarea remains usable; server validation enforces body limits.

Editor build sources and Lexical/Heroicons licenses are included. Rebuild with
`npm ci && npm run build`; installation uses the committed bundle and needs no Node.

Request schemas use `topenapi` 0.2.0; see `assets/operations.json` and the mounting guide.

For reusable profile widgets, see the [widget contract](https://github.com/jerily/web-user/blob/main/WIDGETS.md)
and the host-wiring example in [MOUNTING.md](MOUNTING.md).

Mount configuration accepts `assets_url` to supply the browser-asset base URL,
for example `https://cdn.example/cdn/forum/_assets`.
Templates receive this value as `assets`; the default is the mount prefix plus
`/_assets`, and local asset routes remain available. The host is responsible for
uploading these files and allowing the CDN in its content security policy.

## Ordering and moderation

The topic list defaults to **Newest topics**. Visitors can choose **Latest
activity**, based on the newest visible approved reply, or the topic's creation
time when there are no replies. Pending/hidden replies do not bump a discussion.
Replies run oldest first. Pagination preserves the selected order.

Grant `forum.moderate` through `web-user` groups/permissions. Moderators see the
pending queue, hidden posts, and audit history, plus conditional action links.
Actions open a reason form and only change state on a CSRF-protected POST.
Approval, visibility, and locking are separate states: restoring a hidden pending
post does not publish it. No hard-delete operation is exposed.

See [MOUNTING.md](MOUNTING.md) for settings, routes, schema initialization,
CAPTCHA policy, image renderer integration, and permission setup.

## Deferred loading

`::web::core::manifest web-forum` reads [api.json](api.json) without loading
the application handlers. Pass the manifest, prefix and mount configuration to
`::web::core::route_plan` to resolve bindings, middleware, and routes.

`::web::forum::prepare_mount` accepts the same options as `mount`, without the
router argument, and prepares resources without registering routes. The normal
`mount` procedure uses the same route definitions. Keep the returned configuration
for the mount's lifetime; a lazy dispatcher prepares it once on first use.
Both APIs retain the `-secret_config` option.

The `template_renderer` entry in `-config` accepts a trusted command prefix. It
receives `name json` (plus an optional override dictionary for static content)
and returns rendered HTML. When supplied, mounting does not read template files
or embed template strings in the configuration. The host owns rendering caches
and must validate the complete package/layout composition during packaging/CI.
The existing `master_template`, `templates`, and `prepare_templates` APIs remain
available for compatibility and artifact validation.

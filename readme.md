# web-forum

A minimal community discussion package. Public visitors can read the newest 100
threads and latest 100 replies; authenticated members can create a thread or reply.
Titles are escaped plain text. Bodies are stored as Markdown and rendered with
`cmark-gfm-tcl`, which omits raw HTML and unsafe link destinations. New topics and
replies use the same visual/source Markdown editor as web-wiki and web-blog. There is no moderation, deletion,
file upload, pagination or role system in this initial version.

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
`body csrf`. IDs use `ksuid-tcl`. Posts are limited to 10000 characters and titles
to 160; members are limited to 30 posting attempts per 15 minutes. Public author
labels show a shortened user ID rather than exposing email addresses. Anonymous
GET of the new-thread form redirects to login; anonymous POST is rejected.

Configuration accepts `prefix`, `title`, `master_template`, named `templates`,
typed template `properties`, `page_size` (100), `body_max_length` (10000),
`title_max_length` (160), and `post_limit` (30). Limits above are defaults.
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

# web-forum (private)

A minimal community discussion package. Public visitors can read the newest 100
threads and latest 100 replies; authenticated members can create a thread or reply.
Titles and bodies are plain text escaped by Jinja. There is no moderation, deletion,
file upload, pagination or role system in this initial version.

```tcl
package require web-forum
::web::forum::initdb $connection
set forum [::web::forum::mount $router -store $accountStore -user $accountMount \
    -prefix /forum -config [dict create master_template $siteMaster]]
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

Configuration accepts `title`, `master_template`, and named `templates` overrides.
The master defines `{% block body %}`. See web-user's MOUNTING.md and the complete
`example-community` host, which also mounts unchanged web-wiki and web-blog.

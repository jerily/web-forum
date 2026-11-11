package require web-user 0.2.0
package require cmark_gfm 0.1.0
package require topenapi 0.2.0
namespace eval ::web::forum {
    variable root [file dirname [file dirname [info script]]]
    namespace import ::tpersist::db_*
}
source [file join $::web::forum::root library validation.tcl]

# Create discussion tables during explicit site initialization.
proc ::web::forum::initdb {connection} {
    foreach {table columns} {
        web_forum_topics {tenant text id text author text title text body text created_at bigint}
        web_forum_replies {tenant text id text topic text author text body text created_at bigint}
    } {
        set fields {}
        foreach {name type} $columns {dict set fields $name [dict create type $type not_null 1]}
        db_create_table $connection [db_define_table $table $fields -primary_key {tenant id}] -if_not_exists 1
    }
    # Equality prefixes followed by the listing order allow bounded index scans.
    db_create_index $connection web_forum_topics_recent web_forum_topics {tenant created_at id} -if_not_exists 1
    db_create_index $connection web_forum_replies_topic_recent web_forum_replies {tenant topic created_at id} -if_not_exists 1
}

# Capture this site's settings and register each route before catch-all routes.
proc ::web::forum::mount {router args} {
    variable root
    set config [::web::user::options {-store {} -user {} -prefix {} -config {}} {*}$args]
    set settings [::web::user::options {
        prefix /forum title Forum master_template {} templates {} properties {} widgets {}
        page_size 100 body_max_length 10000 title_max_length 160 post_limit 30
    } {*}[dict get $config -config]]
    if {[dict get $config -store] eq {} || [dict get $config -user] eq {}} {error "-store and -user are required"}
    if {[dict get $config -prefix] eq {}} {dict set config -prefix [dict get $settings prefix]}
    foreach key {page_size body_max_length title_max_length post_limit} {
        if {![string is integer -strict [dict get $settings $key]] || [dict get $settings $key] < 1} {error "$key must be a positive integer"}
    }
    set prefix [string trimright [dict get $config -prefix] /]
    if {![regexp {^(/[A-Za-z0-9_-]+)+$} $prefix]} {error "invalid forum prefix"}
    dict set config -prefix $prefix
    set templates {}
    foreach name {page.html.jinja forum.html.jinja} {dict set templates $name [::web::user::read_text [file join $root assets $name]]}
    set templates [dict merge $templates [dict get $settings templates]]
    if {[dict get $settings master_template] ne {}} {dict set templates page.html.jinja [dict get $settings master_template]}
    dict for {name text} $templates {::jinja2::validate $text -templates $templates -path $name}
    dict set config -templates $templates
    dict set config -config $settings
    dict set config -operations [request_operations $settings]
    foreach path [list $prefix $prefix/ $prefix/new $prefix/topic/test $prefix/_assets/editor.css] {
        if {[dict get [$router match GET $path] statusCode] != 404} {error "forum prefix already handled"}
    }
    $router add GET $prefix [list ::web::forum::index $config] -strict true
    $router add GET $prefix/ [list ::web::forum::index $config] -strict true
    $router add {GET POST} $prefix/new [list ::web::forum::new $config] -strict true
    $router add {GET POST} $prefix/topic/:id [list ::web::forum::topic $config] -strict true
    $router add GET $prefix/_assets/:asset ::web::forum::asset -strict true
    return $config
}

# Read a bounded page from this tenant, newest first.
proc ::web::forum::list_rows {store table where limit} {
    set query [db_where [db_select $table] [::web::user::predicate $store $where]]
    set query [db_order_by $query [db_desc [db_col created_at]] [db_desc [db_col id]]]
    set query [db_limit $query $limit]
    dict get [db_execute [dict get $store -connection] $query] rows
}

# Show the public list of recent discussions.
proc ::web::forum::index {config request context params} {
    set store [dict get $config -store]
    set current [::web::user::current_user [dict get $config -user] $request $context]
    set topics [list_rows $store web_forum_topics {} [dict get $config -config page_size]]
    render $config index $current {} $topics $request $context
}

# Show the new-topic form or create a topic for an authenticated member.
proc ::web::forum::new {config request context params} {
    try {
        set auth [dict get $config -user]
        set current [::web::user::current_user $auth $request $context]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $config new $current $request $context]
            if {[string trim [dict get $form title]] eq {}} {
                ::web::user::fail 400 "Enter a topic title."
            }
            set entry [new_entry $current $form]
            dict set entry title [string trim [dict get $form title]]
            set store [dict get $config -store]
            db_transaction [dict get $store -connection] {::web::user::insert $store web_forum_topics $entry}
            return [redirect [dict get $config -prefix]/topic/[dict get $entry id]]
        }
        if {$current eq {}} {return [redirect [dict get $auth -prefix]/login]}
        render $config new $current {} {} $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}

# Show one topic and its replies, or append an authenticated reply.
proc ::web::forum::topic {config request context params} {
    try {
        set store [dict get $config -store]
        set id [dict get $params id]
        validate_topic_id $id
        set topic [::web::user::one $store web_forum_topics [dict create id $id]]
        if {$topic eq {}} {::web::user::fail 404 "Topic not found."}
        set current [::web::user::current_user [dict get $config -user] $request $context]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $config reply $current $request $context]
            set entry [new_entry $current $form]
            dict set entry topic $id
            db_transaction [dict get $store -connection] {::web::user::insert $store web_forum_replies $entry}
            return [redirect [dict get $config -prefix]/topic/$id]
        }
        set replies [lreverse [list_rows $store web_forum_replies [dict create topic $id] [dict get $config -config page_size]]]
        render $config topic $current $topic $replies $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}

# Shared write guard; topic and reply handlers decide what record to create.
proc ::web::forum::post_form {config action current request context} {
    if {$current eq {}} {::web::user::fail 401 "Sign in to post."}
    set store [dict get $config -store]
    set form [::web::user::form $request [::web::user::property $store form_max_bytes]]
    if {![dict exists $form csrf] ||
        ![::web::user::csrf [dict get $config -user] verify $request $context [dict get $form csrf]]} {
        ::web::user::fail 403 "Invalid CSRF token."
    }
    ::web::user::validate_form $request $form [dict get $config -operations $action]
    if {[string trim [dict get $form body]] eq {}} {::web::user::fail 400 "Enter a message."}
    ::web::user::throttle $store [list forum [dict get $current id]] [dict get $config -config post_limit]
    return $form
}

# Assign a new KSUID while storing the submitted Markdown unchanged.
proc ::web::forum::new_entry {current form} {
    dict create id [::ksuid::generate_ksuid] author [dict get $current id] body [dict get $form body] created_at [clock seconds]
}

# Send the browser to the canonical topic URL after a successful write.
proc ::web::forum::redirect {location} {
    set result [::web::user::response 303 {}]
    dict set result headers location $location
    return $result
}

# Expose expected validation errors without catching unexpected failures.
proc ::web::forum::request_error {message opts} {
    ::web::user::response [lindex [dict get $opts -errorcode] 2] $message {text/plain; charset=utf-8}
}

# Format stored Unix seconds in UTC, independent of the server's timezone.
proc ::web::forum::timestamp {seconds} {
    dict create datetime [clock format $seconds -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] \
        label [clock format $seconds -gmt 1 -format {%Y-%m-%d %H:%M UTC}]
}

# Build typed template data and render Markdown with raw HTML disabled.
proc ::web::forum::render {config view current topic items request context} {
    set auth [dict get $config -user]
    set prefix [dict get $config -prefix]
    set fields [dict create title [dict get $config -config title] brand [dict get $config -config title] prefix $prefix \
        view $view topic_title {} topic_html {} topic_profile_widget {} \
        topic_created_at_datetime {} topic_created_at_label {} \
        action_url $prefix/new login_url [dict get $auth -prefix]/login csrf {} \
        assets $prefix/_assets body_max_length [dict get $config -config body_max_length] title_max_length [dict get $config -config title_max_length]]
    set profiles {}
    if {$topic ne {}} {
        set author [dict get $topic author]
        dict set profiles $author [render_widget $config profile [dict create user_id $author] $request $context]
        dict set fields topic_profile_widget [dict get $profiles $author]
        set createdAt [timestamp [dict get $topic created_at]]
        dict set fields topic_created_at_datetime [dict get $createdAt datetime]
        dict set fields topic_created_at_label [dict get $createdAt label]
        dict set fields topic_title [dict get $topic title]
        dict set fields topic_html [::cmark_gfm::render_gfm_html [dict get $topic body]]
        dict set fields action_url $prefix/topic/[dict get $topic id]
    }
    if {$current ne {}} {dict set fields csrf [::web::user::csrf $auth issue $request $context {}]}
    set typed [dict merge [dict get $config -config properties] [::web::user::text_fields $fields]]
    dict set typed signed_in [list BOOL [expr {$current ne {}}]]
    dict set typed editing [list BOOL [expr {$current ne {} && $view ne "index"}]]
    set values {}
    foreach item $items {
        set createdAt [timestamp [dict get $item created_at]]
        dict set item created_at_datetime [dict get $createdAt datetime]
        dict set item created_at_label [dict get $createdAt label]
        dict set item body_html [::cmark_gfm::render_gfm_html [dict get $item body]]
        dict set item url $prefix/topic/[dict get $item id]
        set author [dict get $item author]
        if {![dict exists $profiles $author]} {
            dict set profiles $author [render_widget $config profile [dict create user_id $author] $request $context]
        }
        dict set item member Member
        dict set item profile_widget [dict get $profiles $author]
        lappend values [list M [::web::user::text_fields $item]]
    }
    dict set typed items [list L $values]
    set templates [dict get $config -templates]
    set body [::jinja2::render [dict get $templates forum.html.jinja] \
        [::tjson::typed_to_json [list M $typed]] -templates $templates -path forum.html.jinja]
    ::web::user::response 200 $body
}

# The host binds trusted widget providers. Cache repeated authors per render above.
# Providers own data access, escaping and markup; an unconfigured widget is empty.
proc ::web::forum::render_widget {config name properties request context} {
    set widgets [dict get $config -config widgets]
    if {![dict exists $widgets $name]} {return {}}
    set command [dict get $widgets $name]
    if {$command eq {}} {return {}}
    {*}$command $properties $request $context
}

# Serve only the bundled editor assets; never accept a filesystem path.
proc ::web::forum::asset {request context params} {
    variable root
    set name [dict get $params asset]
    set types {editor.css text/css markdown-editor.bundle.js text/javascript}
    if {![dict exists $types $name]} {return [::web::user::response 404 {Asset not found.} text/plain]}
    set result [::web::user::response 200 [::web::user::read_text [file join $root assets $name]] "[dict get $types $name]; charset=utf-8"]
    dict set result headers cache-control {public, max-age=3600}
    return $result
}
package provide web-forum 0.1.9

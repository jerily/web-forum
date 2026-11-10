package require web-user 0.1.2
package require cmark_gfm 0.1.0
namespace eval ::web::forum {
    variable root [file dirname [file dirname [info script]]]
    namespace import ::tpersist::db_*
}
proc ::web::forum::initdb {connection} {
    foreach {table columns} {
        web_forum_topics {tenant text id text author text title text body text created_at bigint}
        web_forum_replies {tenant text id text topic text author text body text created_at bigint}
    } {
        set fields {}
        foreach {name type} $columns {dict set fields $name [dict create type $type not_null 1]}
        db_create_table $connection [db_define_table $table $fields -primary_key {tenant id}] -if_not_exists 1
    }
}
proc ::web::forum::mount {router args} {
    variable root
    set c [::web::user::options {-store {} -user {} -prefix {} -config {}} {*}$args]
    set settings [::web::user::options {prefix /forum master_template {} templates {} title Forum properties {} page_size 100 body_max_length 10000 title_max_length 160 post_limit 30} {*}[dict get $c -config]]
    if {[dict get $c -store] eq {} || [dict get $c -user] eq {}} {error "-store and -user are required"}
    if {[dict get $c -prefix] eq {}} {dict set c -prefix [dict get $settings prefix]}
    foreach key {page_size body_max_length title_max_length post_limit} {
        if {![string is integer -strict [dict get $settings $key]] || [dict get $settings $key] < 1} {error "$key must be a positive integer"}
    }
    set prefix [string trimright [dict get $c -prefix] /]
    if {![regexp {^(/[A-Za-z0-9_-]+)+$} $prefix]} {error "invalid forum prefix"}
    dict set c -prefix $prefix
    set templates {}
    foreach name {page.html.jinja forum.html.jinja} {dict set templates $name [::web::user::read_text [file join $root assets $name]]}
    set templates [dict merge $templates [dict get $settings templates]]
    if {[dict get $settings master_template] ne {}} {dict set templates page.html.jinja [dict get $settings master_template]}
    dict for {name text} $templates {::jinja2::validate $text -templates $templates -path $name}
    dict set c -templates $templates
    dict set c -config $settings
    foreach path [list $prefix $prefix/ $prefix/new $prefix/topic/test $prefix/_assets/editor.css] {
        if {[dict get [$router match GET $path] statusCode] != 404} {error "forum prefix already handled"}
    }
    $router add GET $prefix [list ::web::forum::index $c] -strict true
    $router add GET $prefix/ [list ::web::forum::index $c] -strict true
    $router add {GET POST} $prefix/new [list ::web::forum::new $c] -strict true
    $router add {GET POST} $prefix/topic/:id [list ::web::forum::topic $c] -strict true
    $router add GET $prefix/_assets/:asset ::web::forum::asset -strict true
    return $c
}
proc ::web::forum::list_rows {store table where limit} {
    set query [db_limit [db_order_by [db_where [db_select $table] [::web::user::predicate $store $where]] [db_desc [db_col created_at]] [db_desc [db_col id]]] $limit]
    dict get [db_execute [dict get $store -connection] $query] rows
}
proc ::web::forum::index {c request context params} {
    set store [dict get $c -store]
    set current [::web::user::current_user [dict get $c -user] $request $context]
    render $c index $current {} [list_rows $store web_forum_topics {} [dict get $c -config page_size]] $request $context
}
proc ::web::forum::new {c request context params} {
    try {
        set auth [dict get $c -user]
        set current [::web::user::current_user $auth $request $context]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $c $current $request $context]
            if {![dict exists $form title] || [string trim [dict get $form title]] eq {} || [string length [dict get $form title]] > [dict get $c -config title_max_length]} {
                ::web::user::fail 400 "Title must contain 1..[dict get $c -config title_max_length] characters."
            }
            set entry [new_entry $current $form]
            dict set entry title [string trim [dict get $form title]]
            set store [dict get $c -store]
            db_transaction [dict get $store -connection] {::web::user::insert $store web_forum_topics $entry}
            return [redirect [dict get $c -prefix]/topic/[dict get $entry id]]
        }
        if {$current eq {}} {return [redirect [dict get $auth -prefix]/login]}
        render $c new $current {} {} $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
proc ::web::forum::topic {c request context params} {
    try {
        set store [dict get $c -store]
        set id [dict get $params id]
        if {![regexp {^[0-9A-Za-z]{27}$} $id]} {::web::user::fail 404 "Topic not found."}
        set topic [::web::user::one $store web_forum_topics [dict create id $id]]
        if {$topic eq {}} {::web::user::fail 404 "Topic not found."}
        set current [::web::user::current_user [dict get $c -user] $request $context]
        if {[dict get $request method] eq "POST"} {
            set form [post_form $c $current $request $context]
            set entry [new_entry $current $form]
            dict set entry topic $id
            db_transaction [dict get $store -connection] {::web::user::insert $store web_forum_replies $entry}
            return [redirect [dict get $c -prefix]/topic/$id]
        }
        set replies [lreverse [list_rows $store web_forum_replies [dict create topic $id] [dict get $c -config page_size]]]
        render $c topic $current $topic $replies $request $context
    } trap {WEB USER} {message opts} {request_error $message $opts}
}
# Shared write guard; topic and reply handlers decide what record to create.
proc ::web::forum::post_form {c current request context} {
    if {$current eq {}} {::web::user::fail 401 "Sign in to post."}
    set store [dict get $c -store]
    set form [::web::user::form $request [::web::user::property $store form_max_bytes]]
    if {![dict exists $form csrf] || ![::web::user::csrf [dict get $c -user] verify $request $context [dict get $form csrf]]} {::web::user::fail 403 "Invalid CSRF token."}
    if {![dict exists $form body] || [string trim [dict get $form body]] eq {} || [string length [dict get $form body]] > [dict get $c -config body_max_length]} {
        ::web::user::fail 400 "Post must contain 1..[dict get $c -config body_max_length] characters."
    }
    ::web::user::throttle $store [list forum [dict get $current id]] [dict get $c -config post_limit]
    return $form
}
proc ::web::forum::new_entry {current form} {
    dict create id [::ksuid::generate_ksuid] author [dict get $current id] body [dict get $form body] created_at [clock seconds]
}
proc ::web::forum::redirect {location} {
    set result [::web::user::response 303 {}]
    dict set result headers location $location
    return $result
}
proc ::web::forum::request_error {message opts} {
    ::web::user::response [lindex [dict get $opts -errorcode] 2] $message {text/plain; charset=utf-8}
}
proc ::web::forum::render {c view current topic items request context} {
    set auth [dict get $c -user]
    set prefix [dict get $c -prefix]
    set fields [dict create title [dict get $c -config title] brand [dict get $c -config title] prefix $prefix \
        view $view topic_title {} topic_html {} action_url $prefix/new login_url [dict get $auth -prefix]/login csrf {} \
        assets $prefix/_assets body_max_length [dict get $c -config body_max_length] title_max_length [dict get $c -config title_max_length]]
    if {$topic ne {}} {
        dict set fields topic_title [dict get $topic title]
        dict set fields topic_html [::cmark_gfm::render_gfm_html [dict get $topic body]]
        dict set fields action_url $prefix/topic/[dict get $topic id]
    }
    if {$current ne {}} {dict set fields csrf [::web::user::csrf $auth issue $request $context {}]}
    set typed [dict merge [dict get $c -config properties] [::web::user::text_fields $fields]]
    dict set typed signed_in [list BOOL [expr {$current ne {}}]]
    dict set typed editing [list BOOL [expr {$current ne {} && $view ne "index"}]]
    set values {}
    foreach item $items {
        dict set item body_html [::cmark_gfm::render_gfm_html [dict get $item body]]
        dict set item url $prefix/topic/[dict get $item id]
        dict set item member "Member [string range [dict get $item author] end-5 end]"
        lappend values [list M [::web::user::text_fields $item]]
    }
    dict set typed items [list L $values]
    set templates [dict get $c -templates]
    ::web::user::response 200 [::jinja2::render [dict get $templates forum.html.jinja] [::tjson::typed_to_json [list M $typed]] -templates $templates -path forum.html.jinja]
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
package provide web-forum 0.1.2

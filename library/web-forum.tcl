package require web-user 0.1.0
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
    set c [::web::user::options {-store {} -user {} -prefix /forum -config {}} {*}$args]
    set settings [::web::user::options {master_template {} templates {} title Forum} {*}[dict get $c -config]]
    if {[dict get $c -store] eq {} || [dict get $c -user] eq {}} {error "-store and -user are required"}
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
    foreach path [list $prefix $prefix/ $prefix/new $prefix/topic/test] {
        if {[dict get [$router match GET $path] statusCode] != 404} {error "forum prefix already handled"}
    }
    foreach {methods path action} [list GET $prefix index GET $prefix/ index {GET POST} $prefix/new new {GET POST} $prefix/topic/:id topic] {
        $router add $methods $path [list ::web::forum::dispatch $c $action] -strict true
    }
    return $c
}
proc ::web::forum::list_rows {store table where} {
    set query [db_limit [db_order_by [db_where [db_select $table] [::web::user::predicate $store $where]] [db_desc [db_col created_at]] [db_desc [db_col id]]] 100]
    dict get [db_execute [dict get $store -connection] $query] rows
}
proc ::web::forum::dispatch {c action request context params} {
    try {
        set store [dict get $c -store]
        set auth [dict get $c -user]
        set current [::web::user::current_user $auth $request $context]
        set prefix [dict get $c -prefix]
        set fields [dict create title [dict get $c -config title] brand [dict get $c -config title] prefix $prefix \
            view $action topic_title {} topic_body {} action_url $prefix/new login_url [dict get $auth -prefix]/login csrf {}]
        set items {}
        if {$action eq "topic"} {
            set id [dict get $params id]
            if {![regexp {^[0-9A-Za-z]{27}$} $id]} {::web::user::fail 404 "Topic not found."}
            set topic [::web::user::one $store web_forum_topics [dict create id $id]]
            if {$topic eq {}} {::web::user::fail 404 "Topic not found."}
            dict set fields topic_title [dict get $topic title]
            dict set fields topic_body [dict get $topic body]
            dict set fields action_url $prefix/topic/$id
            set items [lreverse [list_rows $store web_forum_replies [dict create topic $id]]]
        } elseif {$action eq "index"} {set items [list_rows $store web_forum_topics {}]}
        if {$action eq "new" && $current eq {} && [dict get $request method] ne "POST"} {
            set result [::web::user::response 303 {}]
            dict set result headers location [dict get $auth -prefix]/login
            return $result
        }
        if {[dict get $request method] eq "POST"} {
            if {$current eq {}} {::web::user::fail 401 "Sign in to post."}
            set form [::web::user::form $request]
            if {![dict exists $form csrf] || ![::web::user::csrf $auth verify $request $context [dict get $form csrf]]} {::web::user::fail 403 "Invalid CSRF token."}
            if {![dict exists $form body] || [string trim [dict get $form body]] eq {} || [string length [dict get $form body]] > 10000} {::web::user::fail 400 "Post must contain 1..10000 characters."}
            ::web::user::throttle $store [list forum [dict get $current id]] 30
            set entry [dict create id [::ksuid::generate_ksuid] author [dict get $current id] body [dict get $form body] created_at [clock seconds]]
            if {$action eq "new"} {
                if {![dict exists $form title] || [string trim [dict get $form title]] eq {} || [string length [dict get $form title]] > 160} {::web::user::fail 400 "Title must contain 1..160 characters."}
                dict set entry title [string trim [dict get $form title]]
                set table web_forum_topics
                set id [dict get $entry id]
            } else {
                dict set entry topic $id
                set table web_forum_replies
            }
            db_transaction [dict get $store -connection] {::web::user::insert $store $table $entry}
            set result [::web::user::response 303 {}]
            dict set result headers location $prefix/topic/$id
            return $result
        }
        if {$current ne {}} {dict set fields csrf [::web::user::csrf $auth issue $request $context {}]}
        set typed [::web::user::text_fields $fields]
        dict set typed signed_in [list BOOL [expr {$current ne {}}]]
        set values {}
        foreach item $items {
            dict set item url $prefix/topic/[dict get $item id]
            dict set item member "Member [string range [dict get $item author] end-5 end]"
            lappend values [list M [::web::user::text_fields $item]]
        }
        dict set typed items [list L $values]
        set templates [dict get $c -templates]
        ::web::user::response 200 [::jinja2::render [dict get $templates forum.html.jinja] [::tjson::typed_to_json [list M $typed]] -templates $templates -path forum.html.jinja]
    } trap {WEB USER} {message opts} {::web::user::response [lindex [dict get $opts -errorcode] 2] $message {text/plain; charset=utf-8}}
}
package provide web-forum 0.1.0

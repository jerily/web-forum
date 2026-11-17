# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Load the forum package and its storage dependencies.
package require tpersist 0.1.4
package require web-user 0.5.4
package require ksuid 1.0.5
package require cmark_gfm 0.1.0
package require topenapi 0.2.0
namespace eval ::web::forum {
    variable root [file dirname [file dirname [info script]]]
    namespace import ::tpersist::db_*
}
source [file join $::web::forum::root library validation.tcl]

# Create discussion tables during explicit site initialization.
proc ::web::forum::initdb {connection} {
    variable root
    db_apply_schema $connection [file join $root sql schema.json] -additive true
    initialize_activity $connection
}

# Capture this site's settings and register each route before catch-all routes.
proc ::web::forum::mount {router args} {
    variable root
    set config [::web::user::options {-store {} -user {} -prefix {} -config {}} {*}$args]
    set settings [::web::user::options {
        prefix /forum title Forum master_template {} templates {} properties {} widgets {} render_markdown {} assets_url {}
        page_size 20 body_max_length 10000 title_max_length 160 post_limit 30 moderation false posting_captcha false
    } {*}[dict get $config -config]]
    if {[dict get $config -store] eq {} || [dict get $config -user] eq {}} {error "-store and -user are required"}
    if {[dict get $config -prefix] eq {}} {dict set config -prefix [dict get $settings prefix]}
    foreach key {page_size body_max_length title_max_length post_limit} {
        if {![string is integer -strict [dict get $settings $key]] || [dict get $settings $key] < 1} {error "$key must be a positive integer"}
    }
    if {[dict get $settings page_size] > 100} {error "page_size must be at most 100"}
    if {![string is boolean -strict [dict get $settings moderation]]} {error "moderation must be a boolean"}
    dict set settings moderation [expr {!![dict get $settings moderation]}]
    if {![string is boolean -strict [dict get $settings posting_captcha]]} {error "posting_captcha must be a boolean"}
    dict set settings posting_captcha [expr {!![dict get $settings posting_captcha]}]
    if {[dict get $settings posting_captcha]} {package require tcaptcha 1.0.0}
    set prefix [string trimright [dict get $config -prefix] /]
    if {![regexp {^(/[A-Za-z0-9_-]+)+$} $prefix]} {error "invalid forum prefix"}
    dict set config -prefix $prefix
    if {[dict get $settings assets_url] eq {}} {dict set settings assets_url $prefix/_assets}
    dict set settings assets_url [string trimright [dict get $settings assets_url] /]
    set templates {}
    set names {page.html.jinja forum.html.jinja}
    foreach filename [lsort [glob -directory [file join $root assets forum] *.html.jinja]] {
        lappend names forum/[file tail $filename]
    }
    foreach name $names {dict set templates $name [::web::user::read_text [file join $root assets $name]]}
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
    $router add GET $prefix/member/:id [list ::web::forum::profile $config] -strict true
    $router add GET $prefix/moderation [list ::web::forum::queue $config] -strict true
    $router add GET $prefix/moderation/history [list ::web::forum::history $config] -strict true
    $router add {GET POST} $prefix/moderate/:kind/:id/:action [list ::web::forum::moderate $config] -strict true
    $router add GET $prefix/_assets/:asset ::web::forum::asset -strict true
    return $config
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
    set types {forum.css text/css editor.css text/css markdown-editor.bundle.js text/javascript}
    if {![dict exists $types $name]} {return [::web::user::response 404 {Asset not found.} text/plain]}
    set result [::web::user::response 200 [::web::user::read_text [file join $root assets $name]] "[dict get $types $name]; charset=utf-8"]
    dict set result headers cache-control {public, max-age=3600}
    return $result
}
foreach module {storage http render} {source [file join $::web::forum::root library $module.tcl]}
package provide web-forum 0.3.2

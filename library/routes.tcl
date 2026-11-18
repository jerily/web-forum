# SPDX-License-Identifier: MIT
# Route declarations only. This package never loads storage or handlers.
namespace eval ::web::forum {
    variable template_directory [file normalize [file join [file dirname [info script]] .. assets]]
}

# Config is opaque here: hosts may bind a placeholder and resolve it on dispatch.
proc ::web::forum::route_specs {prefix config {settings {}} {policy {}}} {
    set prefix [string trimright $prefix /]
    if {![regexp {^(/[A-Za-z0-9_-]+)+$} $prefix]} {error "mount prefix must be a non-root local path"}
    set routes {}
    lappend routes [list GET $prefix [list ::web::forum::index $config]]
    lappend routes [list GET $prefix/ [list ::web::forum::index $config]]
    lappend routes [list {GET POST} $prefix/new [list ::web::forum::new $config]]
    lappend routes [list {GET POST} $prefix/topic/:id [list ::web::forum::topic $config]]
    lappend routes [list GET $prefix/member/:id [list ::web::forum::profile $config]]
    lappend routes [list GET $prefix/moderation [list ::web::forum::queue $config]]
    lappend routes [list GET $prefix/moderation/history [list ::web::forum::history $config]]
    lappend routes [list {GET POST} $prefix/moderate/:kind/:id/:action [list ::web::forum::moderate $config]]
    lappend routes [list GET $prefix/_assets/:asset ::web::forum::asset]
    return $routes
}
package provide web-forum::routes 1.0

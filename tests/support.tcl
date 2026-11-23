package require tcltest
package require web-forum
namespace import ::tcltest::*
namespace eval ::modtest {}
proc ::modtest::setup {{settings {}}} {
    set ::env(ENV) LOCAL
    variable db [::web::user::connect {db_dialect sqlite sqlite_path :memory:}]
    ::web::user::initdb $db {db_dialect sqlite}
    ::web::forum::initdb $db
    variable handles [list [tink::register_keyset [tink::aead::create_keyset AES256_GCM]] [tink::register_keyset [tink::mac::create_keyset HMAC_SHA256]]]
    variable store [::web::user::create -connection $db -config [dict create db_dialect sqlite require_https_origin false secure_cookies false require_email_delivery false aws_email_enabled false tenant forum-tests aead [lindex $handles 0] mac [lindex $handles 1] email_hash_salt test-salt challenge_limit 100]]
    variable router [::tpathexp::router]
    variable auth [::web::user::mount $router -store $store -config {origin http://localhost:8080}]
    ::web::forum::mount $router -store $store -user $auth -config [dict merge {page_size 2 post_limit 100} $settings]
    variable users {}
    foreach name {member moderator outsider} {
        set uid user_[ksuid::generate_ksuid]
        set address $name@example.com
        ::web::user::insert $store web_user_users [dict create id $uid active 1 verified 1 email_key [::web::user::email_key $store $address] email [::web::user::seal $store $address [list email $uid]] password unused mfa_secret {} last_step -1 revision 0 created_at 1]
        set token [::web::user::new_session $store auth $uid]
        set cookie [lindex [split [dict get [::web::user::set_cookie $auth {} $token] headers Set-Cookie] {;}] 0]
        dict set users $name [dict create id $uid token $token cookie $cookie csrf [::web::user::csrf_token $auth $token]]
    }
    ::web::user::sync_access $store {moderators moderator@example.com} {moderators forum.moderate}
}
proc ::modtest::cleanup {} {
    $::modtest::router destroy
    ::tpersist::db_disconnect $::modtest::db
    foreach handle $::modtest::handles {tink::unregister_keyset $handle}
}
proc ::modtest::call {who method target {fields {}} {headers {}}} {
    variable users
    set path [lindex [split $target ?] 0]
    set query [join [lrange [split $target ?] 1 end] ?]
    set request [dict create method $method path $path queryString $query headers $headers]
    if {$who ne {}} {dict set request headers cookie [dict get $users $who cookie]}
    if {$method eq "POST"} {
        if {$who ne {} && ![dict exists $fields csrf]} {dict set fields csrf [dict get $users $who csrf]}
        set pairs {}
        dict for {key value} $fields {lappend pairs [::web::user::uri_component $key]=[::web::user::uri_component $value]}
        dict set request headers content-type application/x-www-form-urlencoded
        dict set request body [join $pairs &]
    }
    $::modtest::router dispatch $request {addr 127.0.0.1}
}
proc ::modtest::topic {{status published} {title Topic}} {
    set id [::web::forum::new_id topics]
    ::web::forum::insert $::modtest::store web_forum_topics [dict create id $id author [dict get $::modtest::users member id] title $title body {Topic body} created_at 1 status $status]
    return $id
}
proc ::modtest::reply {topic {status published}} {
    set id [::web::forum::new_id replies]
    ::web::forum::insert $::modtest::store web_forum_replies [dict create id $id topic $topic author [dict get $::modtest::users member id] body {Reply body} created_at 2 status $status]
    return $id
}
proc ::modtest::action {kind id action {reason {Keep discussions welcoming.}}} {
    set row [::web::forum::one $::modtest::store web_forum_$kind $id]
    call moderator POST /forum/moderate/$kind/$id/$action [dict create reason $reason revision [dict get $row revision]]
}

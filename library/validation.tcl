proc ::web::forum::request_operations {settings} {
    variable root
    set overrides {}
    foreach action {new reply} {
        set path [format {$.%s.requestBody.content['application/x-www-form-urlencoded'].schema.properties.body} $action]
        dict set overrides $path [dict create maxLength [dict get $settings body_max_length]]
    }
    dict set overrides {$.new.requestBody.content['application/x-www-form-urlencoded'].schema.properties.title} \
        [dict create maxLength [dict get $settings title_max_length]]
    ::web::user::read_operations [file join $root assets operations.json] $overrides
}
# Forum record IDs include their resource type, in both paths and query filters.
proc ::web::forum::validate_record_id {kind id} {
    set pattern [format {^%s_[0-9A-Za-z]{27}$} [id_prefix $kind]]
    set schema [::tjson::typed_to_json [list M [dict create type {S string} pattern [list S $pattern]]]]
    set result [::topenapi::validate_schema [::tjson::typed_to_json [list S $id]] $schema]
    if {![dict get $result valid]} {::web::user::fail 404 "Post not found."}
}
# Account IDs belong to web-user, independently of forum record IDs.
proc ::web::forum::validate_member_id {id} {
    set result [::topenapi::validate_schema [::tjson::typed_to_json [list S $id]] \
        {{"type":"string","pattern":"^user_[0-9A-Za-z]{27}$"}}]
    if {![dict get $result valid]} {::web::user::fail 404 "Member not found."}
}
